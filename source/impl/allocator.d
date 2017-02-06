module mergearray.impl.allocator;

/++
Namespace for a static, thread-local region allocator wrapping the GC.
+/
struct GCAllocator {
private:
    static bool in_region = false;
    
public:
    /++
    Returns: Whether or not the allocator's region is active for this thread.
    +/
    @property
    static bool inRegion() { return in_region; }
    /++
    Have the calling thread enter the region.
    
    This allocator does not require scoping allocations within the region, but
    the functionality is provided to be consistent with other allocators.
    +/
    static void enter(size_t) { in_region = true; }
    /++
    Have the calling thread exit the region.
    
    WARNING: This does not deallocate allocated memory, nor are allocations
    guaranteed to survive until this is called.
    +/
    static void exit() { in_region = false; }
    /++
    Allocates the size bytes from the GC and returns a slice to it.
    Params:
    size = Number of bytes to allocate.
    Returns: new void[](size)
    +/
    static void[] alloc(size_t size) in { assert(inRegion()); } body {
        return new void[](size);
    }
    /++
    Allocates a T onto the GC and returns a pointer or class reference to it.
    Params:
    args = Arguments to the constructor of T.
    Returns: new T(args)
    +/
    static auto alloc(T, Args...)(Args args) in { assert(inRegion()); } body {
        return new T(args);
    }
}

/++
Namespace for a static, thread-local region allocator wrapping an
std.experimental.allocator.IAllocator.
+/
struct StdAllocator {
private:
    import std.experimental.allocator : IAllocator, processAllocator, make;
    
    static bool in_region = false;
    
public:
    /++
    Thread-local reference to the allocator backing the region, defaulting to
    std.experimental.allocator.processAllocator.
    +/
    static IAllocator my_allocator = null;
    
    static this() {
        my_allocator = processAllocator;
    }
    
    /++
    Returns: Whether the calling thread is in the region or not.
    +/
    @property
    static bool inRegion() { return in_region; }
    /++
    Have the calling thread enter the region without changing my_allocator.
    +/
    static void enter(size_t) {
        in_region = true;
    }
    /++
    Have the calling thread enter the region, and assign a new my_allocator.
    Params:
    ia = An allocator to assign to my_allocator.
    +/
    static void enter(IAllocator ia) {
        in_region = true;
        my_allocator = ia;
    }
    /++
    Have the calling thread exit the region.
    
    WARNING: Does not mutate my_allocator. Deconstructors and deallocation must
    be handled manually through my_allocator.
    +/
    static void exit() {
        in_region = false;
    }
    /++
    Allocates size bytes from my_allocator and returns a slice to it.
    Params:
    size = Number of bytes from my_allocator to allocate.
    Returns: A slice to the size bytes from my_allocator.
    +/
    static auto alloc(size_t size) in { assert(inRegion()); } body {
        import std.stdio;
        debug(mergearray_allocator) writeln(size);
        return my_allocator.allocate(size);
    }
    /++
    Makes a T using my_allocator, and returns a pointer to it.
    Params:
    args = Arguments to the constructor of T.
    Returns: A pointer or class reference to the T that my_allocator made.
    +/
    static auto alloc(T, Args...)(Args args) in { assert(inRegion()); } body {
        import std.stdio;
        debug(mergearray_allocator) writeln(T.stringof, " = ", T.sizeof);
        return my_allocator.make!T(args);
    }
}

/++
Namespace for a static, thread-local, non-nested, unbounded-size allocator.

Memory is allocated bump-the-pointer style within large GC-allocated chunks.
A new chunk is allocated when the current one is too full for the next request.
Deallocation of chunks is handled by the GC, and destructors are not called.
+/
struct ChunkGCAllocator {
private:
    static void[] region;
    static size_t curPos = 0;
    static size_t allocSize = 0;//2 ^^ 27; // 128MB
    static size_t prevAllocs = 0;
    static bool in_region = false;
    
    debug(mergearray_allocator) import std.stdio;
    
    static void replace() {
        debug(mergearray_allocator) {
            writefln("%s replace: allocating %s bytes.", typeof(this).stringof, allocSize);
        }
        prevAllocs += region.length;
        
        region = new void[](allocSize);
        
        curPos = 0;
    }
    
public:
    /++
    Peek at the current head of the region.
    This value can be used to check how many bytes have been allocated so far
    in the current chunk.
    +/
    static size_t peek() { return curPos; }
    /++
    Returns: Whether the calling thread is in the region or not.
    +/
    static bool inRegion() { return in_region; }
    /++
    Have the calling thread enter the region with a chunks of size chunkSize.
    Params:
    chunkSize = The size of allocated chunks throughout the region.
    +/
    static void enter(size_t chunkSize) {
        allocSize = chunkSize;
        in_region = true;
        replace();
        debug(mergearray_allocator) {
            writefln("%s enter: %s/%s bytes free.", typeof(this).stringof, region.length - curPos, region.length + prevAllocs);
        }
    }
    /++
    Have the calling thread exit the region, releasing any references to an
    allocated chunk.
    
    WARNING: This does not deallocate allocated memory, nor are allocations
    guaranteed to survive until this is called, nor are deconstructors called.
    +/
    static void exit() {
        debug(mergearray_allocator) {
            writefln("%s exit:  %s/%s bytes free.", typeof(this).stringof, region.length - curPos, region.length + prevAllocs);
        }
        in_region = false;
        region = null;
        prevAllocs = 0;
    }
    /++
    Allocates the next size bytes from the region and returns a slice to it.
    
    If the current chunk is too full, then a new one is allocated and used.
    Params:
    size = Number of bytes from the region to allocate.
    Returns: A slice to the next size unused bytes from the region.
    +/
    static void[] alloc(size_t size) in { assert(inRegion()); } body {
        if (curPos + size > region.length) {
            replace();
        }
        scope(success) curPos += size;
        
        debug(mergearray_allocator) writefln("%s alloc: %s bytes allocated.", typeof(this).stringof, size);
        
        return region[curPos .. curPos + size];
    }
    /++
    Allocates at least T.sizeof bytes, emplaces a T there, and returns a pointer to it.
    
    The allocation IS automatically padded to ensure proper alignment.
    Params:
    args = Arguments to the constructor of T.
    Returns: A pointer or class reference to the allocated and emplaced T.
    +/
    static auto alloc(T, Args...)(Args args) in { assert(inRegion()); } body {
        size_t alignOffset = (T.alignof - curPos % T.alignof);
        
        if (curPos + T.sizeof + alignOffset > region.length) {
            replace();
            alignOffset = 0;
        }
        
        immutable size = T.sizeof + alignOffset;
        
        scope(success) curPos += size;
        
        assert(curPos + size <= region.length);
        void[] slice = region[curPos + alignOffset .. curPos + size];
        
        assert(slice.length == T.sizeof);
        return emplace!T(slice, args);
    }
}

/++
Namespace for a static, thread-local, non-nested, bounded-size region allocator.

Memory is allocated bump-the-pointer style within one buffer which must not
overflow. Exiting will free the buffer without calling destructors.
+/
struct TLRegionAllocator {
private:
    import core.memory;
    
    static void[] buffer = null;
    static size_t curPos = 0;
    
    debug(mergearray_allocator) import std.stdio;
    
public:
    /++
    Returns: Whether the calling thread is in the region or not.
    +/
    @property
    static bool inRegion() {
        return buffer !is null;
    }
    /++
    Peek at the current head of the region.
    
    This value can be used to check how many bytes have been allocated so far,
    and to determine the alignment of the next allocation.
    +/
    static size_t peek() { return curPos; }
    
    /++
    Have the calling thread enter the region with a given size maxBytes.
    Params:
    maxBytes = The number of bytes to initialize the region to.
    +/
    static void enter(size_t maxBytes) {
        debug(mergearray_allocator) writefln("%s enter: %s bytes allocating...", typeof(this).stringof, maxBytes);
        
        buffer = GC.malloc(maxBytes)[0 .. maxBytes];
        
        assert(buffer.length == maxBytes);
        
        curPos = 0;
        debug(mergearray_allocator) writefln("%s enter: %s bytes allocated.", typeof(this).stringof, buffer.length);
    }
    
    /++
    Have the calling thread exit the region, deallocating the memory.
    WARNING: Destructors of allocated structs or objects are not called.
    +/
    static void exit() {
        debug(mergearray_allocator) writefln("%s exit: %s/%s (%s%%) bytes used.", typeof(this).stringof, curPos, buffer.length, curPos * 100.0 / buffer.length);
        
        auto ptr = buffer.ptr;
        buffer = null;
        GC.free(ptr);
    }
    
    /++
    Allocates the next size bytes from the region and returns a slice to it.
    Params:
    size = Number of bytes from the region to allocate.
    Returns: A slice to the next size unused bytes from the region.
    +/
    static void[] alloc(size_t size)
    in {
        assert(inRegion());
        
        version(assert) {
            import std.string : format;
            
            assert(curPos + size <= buffer.length,
                "%s alloc: attempt to alloc %s but only %s/%s free"
                .format(typeof(this).stringof, size, buffer.length - curPos, buffer.length)
            );
        }
    }
    body {
        scope(exit) curPos += size;
        
        debug(mergearray_allocator) writefln("%s alloc: %s bytes allocated.", typeof(this).stringof, size);
        
        return buffer[curPos .. curPos + size];
    }
    /++
    Allocates T.sizeof bytes, emplaces a T there, and returns a pointer to it.
    Warning: The allocation is NOT automatically padded to ensure proper alignment.
    Params:
    args = Arguments to the constructor of T.
    Returns: A pointer or class reference to the allocated and emplaced T.
    +/
    static auto alloc(T, Args...)(Args args)
    in {
        assert(inRegion());
        assert(curPos % T.alignof == 0);
    }
    body {
        auto space = alloc(T.sizeof);
        
        import std.conv : emplace;
        
        return emplace!T(space, args);
    }
}

// unused/unpolished
static if (false)
struct TLStaticAllocator {
private:
    static void[length] buffer = void;
    static size_t curPos = size_t.max;
    
    debug(mergearray_allocator) import std.stdio;
    
public:
    enum size_t length = 2 ^^ 26;
    
    static bool inRegion() {
        return curPos <= length;
    }
    
    static size_t peek() { return curPos; }
    
    static void enter(size_t maxBytes = 0) in { assert(maxBytes <= length); } body {
        curPos = 0;
        
        debug(mergearray_allocator) writefln("%s enter: %s bytes allocated.", typeof(this).stringof, length);
    }
    
    static void exit() {
        debug(mergearray_allocator) writefln("%s exit: %s/%s (%s%%) bytes used.", typeof(this).stringof, curPos, buffer.length, curPos * 100.0 / buffer.length);
        curPos = size_t.max;
    }
    
    static auto alloc(size_t size)
    in {
        assert(inRegion());
        assert(curPos + size <= buffer.length);
    }
    body {
        scope(exit) curPos += size;
        
        debug(mergearray_allocator) writefln("%s alloc: %s bytes allocated.", typeof(this).stringof, size);
        
        return buffer[curPos .. curPos + size];
    }
    
    static auto alloc(T, Args...)(Args args)
    in {
        assert(inRegion());
        assert(curPos + T.sizeof <= buffer.length);
        assert(curPos % T.alignof == 0);
    }
    body {
        scope(exit) curPos += T.sizeof;
        
        import std.conv;
        
        return emplace!T(buffer[curPos .. curPos + T.sizeof], args);
    }
}

