module mergearray.impl.header;

version(mergearray_use_numeric_tid) {
    /++
    Unique thread identifier of type size_t.
    
    This is used for errors and debugging when
    version(mergearray_use_numeric_tid) is set.
    +/
    shared size_t tidCount = 0;
    /// ditto
    size_t tid = 0;
    
    static this() {
        synchronized {
            tid = tidCount;
            tidCount = tid + 1;
        }
    }
}
else {
    import std.concurrency : thisTid;
    /++
    Unique thread identifier of type std.concurrency.Tid.
    
    This is used for errors and debugging when
    version(mergearray_use_numeric_tid) is not set.
    +/
    alias tid = thisTid;
    //Tid tid() { return thisTid(); }
}

// =============================================================================

version (mergearray_do_cas_statistics) {
    /++
    Instrumented compare-and-swap to record usage statistics for debugging or
    performance measurements.
    
    This is used when version(mergearray_do_cas_statistics) is set.
    +/
    size_t numSuccessfulCAS = 0;
    /// ditto
    size_t numFailedCAS = 0;
    
    /// ditto
    bool my_cas(L,E,V)(L* loc, E expected, V value) {
        import core.atomic : cas;
        
        if (cas(loc,expected,value)) {
            numSuccessfulCAS++;
            return true;
        }
        else {
            numFailedCAS++;
            return false;
        }
    }
    
    /++
    Resets instrumented compare-and-swap statistics to zero.
    
    This is used when version(mergearray_do_cas_statistics) is set.
    +/
    void resetCasStats() {
        numSuccessfulCAS = 0;
        numFailedCAS = 0;
    }
}
else {
    import core.atomic : cas;
    /++
    Uninstrumented compare-and-swap.
    
    This is used when version(mergearray_do_cas_statistics) is not set.
    +/
    alias my_cas = cas;
}

//==============================================================================

version (mergearray_do_lock_statistics) {
    /++
    Instrumentation variables to record usage statistics of SMutex and TasMutex
    for debugging or performance measurements.
    
    This is used when version(mergearray_do_lock_statistics) is set.
    +/
    size_t tryLockFails = 0;
    /// ditto
    size_t tryLockSuccess = 0;
    /// ditto
    size_t lockTotal = 0;
    
    /// ditto
    void resetLockStats() {
        tryLockFails = 0;
        tryLockSuccess = 0;
        lockTotal = 0;
    }
}

//==============================================================================

/++
Scoped wrapper for a shared(core.sync.mutex.Mutex).
+/
struct SMutex {
private:
    import core.sync.mutex : Mutex;
    
    Mutex mutex;
    
public:
    /++
    Returns: An unshared reference to the internal Mutex object.
    +/
    @property
    Mutex unshared() shared {
        return cast(Mutex) mutex;
    }
    /++
    Static factory method.
    Params:
    args = Arguments to the Mutex constructor.
    Returns: A shared SMutex, by value.
    +/
    static shared(SMutex) make(Args...)(Args args) {
        return shared SMutex(cast(shared) new Mutex(args));
    }
    /++
    Attempt to lock, and if successful, call dg() then unlock.
    Params:
    dg = A scoped callback that is called only while this is locked.
    Returns: Whether or not the lock was taken.
    +/
    bool tryLocked(scope void delegate() dg) shared {
        if (unshared.tryLock()) {
            scope(exit) unshared.unlock();
            
            version (mergearray_do_lock_statistics) {
                tryLockSuccess++;
                lockTotal++;
            }
            
            dg();
            
            return true;
        }
        else {
            version (mergearray_do_lock_statistics) {
                tryLockFails++;
            }
            return false;
        }
    }
    /++
    Lock, call dg(), then unlock.
    Params:
    dg = A scoped callback that is called only while this is locked.
    +/
    void locked(scope void delegate() dg) shared {
        synchronized (unshared) {
            version (mergearray_do_lock_statistics) {
                lockTotal++;
            }
            dg();
        }
    }
}

/++
Scoped lock wrapping an atomic bool.
+/
struct TasMutex {
    import core.atomic;
    
    private bool lock;
    
    /++
    Static factory method.
    Returns: A shared TasMutex, by value.
    +/
    static shared(TasMutex) make() {
        return shared(TasMutex)(false);
    }
    /++
    Attempt to lock, and if successful, call dg() then unlock.
    Params:
    dg = A scoped callback that is called only while this is locked.
    Returns: Whether or not the lock was taken.
    +/
    bool tryLocked(scope void delegate() dg) shared {
        if (cas(&lock, false, true)) {
            scope(exit) lock.atomicStore(false);
            
            version (mergearray_do_lock_statistics) {
                tryLockSuccess++;
                lockTotal++;
            }
            
            dg();
            
            return true;
        }
        else {
            version (mergearray_do_lock_statistics) {
                tryLockFails++;
            }
            return false;
        }
    }
    /++
    Lock, call dg(), then unlock.
    Params:
    dg = A scoped callback that is called only while this is locked.
    +/
    void locked(scope void delegate() dg) shared {
        while(true) {
            while(lock.atomicLoad) { }
            if (tryLocked(dg)) return;
        }
    }
}
// -----------------------------------------------------------------------------

/++
Shared, coarsely-locked wrapper of an unshared T.
+/
struct CoarseLocked(T) if (!is(T == shared)) {
    alias M = TasMutex; // SMutex
    
    private T t;
    private M mutex;
    
    /++
    Construct from an initial value with a new lock.
    Params:
    init = The initial value for the internal T.
    +/
    this(T init) shared {
        t = cast(shared) init;
        mutex = M.make();
    }
    /++
    Attempt to lock, and if successful, call dg(&t) for internal value t, then unlock.
    Params:
    dg = A scoped callback that is called only while this is locked.
    Returns: Whether or not the lock was taken.
    +/
    bool tryLocked(scope void delegate(T*) dg) shared {
        return mutex.tryLocked({
            T* ptr = cast(T*) &t;
            dg(ptr);
        });
    }
    /++
    Attempt to lock, and if successful, call dg() then unlock.
    Params:
    dg = A scoped callback that is called only while this is locked.
    Returns: Whether or not the lock was taken.
    +/
    bool tryLocked(scope void delegate() dg) shared {
        return mutex.tryLocked(dg);
    }
    /++
    Lock, call dg(&t) for internal value t, then unlock.
    Params:
    dg = A scoped callback that is called only while this is locked.
    +/
    void locked(scope void delegate(T*) dg) shared {
        return mutex.locked({
            T* ptr = cast(T*) &t;
            dg(ptr);
        });
    }
    /++
    Lock, call dg(), then unlock.
    Params:
    dg = A scoped callback that is called only while this is locked.
    +/
    void locked(scope void delegate() dg) shared {
        return mutex.locked(dg);
    }
    /++
    Unshared accessor to the internal T.
    WARNING: This method does not provide mutual exclusion.
    Returns: An unshared pointer to the internal T.
    +/
    T* peek() {
        return &t;
    }
}
