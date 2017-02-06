module mergearray.impl.handle_array;

import core.atomic, core.sync.mutex, std.typecons, std.traits, std.exception;

import mergearray.impl.header;

/++
Possibilities for the result of a merge operation.
+/
enum MergeResult {
    /// The merge was performed successfully.
    Success,
    /// Both objects are already equivalent, so nothing was done.
    WereAlreadyEqual,
    /// ERROR: Both objects were erroneously given the same id, so nothing was done.
    IdClash,
    /// ERROR: The objects are not able to be merged (eg. not the same width), so nothing was done.
    Incompatible
}

/++
A handle to a Union-Find node, referencing a mergeable collection of type Bag.

A Handle is the outer interface of the MergeArray framework for building
relaxed concurrent mergeable data structures. Such a data structure should wrap
a Handle to a Bag type which manages access and merging of sequential data
structures of type Bag.ElementType.
+/
struct Handle(Bag) if (is(Bag == shared) && is(Bag == struct)) {
    /++
    The type of the sequential data structures which applyUntil operates on.
    +/
    alias Obj = Bag.ElementType;
    
private:
    align(32)
    static shared struct Node {
        Bag* bag = null;   // if not null then, as long as next is null, this won't change
        Node* next = null; // monotonic: null -> non-null high id -> non-null lower id -> ...
        immutable size_t id;  // if next is not null then next.id <= id
    }
    
    shared(Node)* ptr = null;
    
    /+
    Moves this to point to the end of its chain of handles
    Any incomplete merges along the way are linearized before this
    +/
    void descend_merging()
    in {
        assert(ptr !is null);
    }
    out {
        assert(ptr !is null);
    }
    body {
        while(true) {
            findClosestBag();
            auto next = ptr.next.atomicLoad;
            
            if (next is null) {
                // found the bottom (for now)
                return;
            }
            else {
                // found (potentially) unfinished work
                ensureMergedInto(Handle(next));
            }
        }
        assert(false);
    }
    
    /+
    Tries to point higher to lower
    +/
    static bool tryLink(shared(Node)* higher, shared(Node)* lower)
    in {
        assert(higher !is null);
        assert(lower !is null);
        assert(lower.id < higher.id);
    }
    body {
        return my_cas(& higher.next, cast(shared(Node)*) null, lower);
    }
    
    /+
    Tries to merge the node chains of the input handles
    If the source has pre-existing links, then it is resolved before a new link is made
    +/
    static auto tryUnion(ref Handle a, ref Handle b)
    in {
        assert(a.ptr !is null);
        assert(b.ptr !is null);
    }
    body {
        struct Result {
            bool merged;
            Handle dest;
        }
        // work on local copy
        while(true) {
            a.descend_merging();
            b.descend_merging();
            
            auto an = a.id;
            auto bn = b.id;
            
            if (a.ptr is b.ptr) {
                // a and b are the same already
                return Result(true, Handle(null));
            }
            else if (an == bn && a.ptr.bag.atomicLoad !is null) {
                // a and b alias to bags of the same id (linearized in 2nd descend_merging)
                return Result(false, Handle(null));
            }
            else if (an < bn && tryLink(b.ptr, a.ptr)) {
                // succeeded at linking b --> a
                return Result(true, a);
            }
            else if (an > bn && tryLink(a.ptr, b.ptr)) {
                // succeeded at linking a --> b
                return Result(true, b);
            }
        }
        
        assert(false);
    }
    
    /+
    Lazily merge all of this bag's elements into next's then linearize them all at once
    +/
    void ensureMergedInto(Handle next)
    in {
        assert(ptr !is null);
        assert(next.ptr !is null);
        assert(this.id > next.id);
    }
    body {
        shared(Bag)* bagSrc = ptr.bag.atomicLoad;
        
        // check that no one else finished for us
        if (bagSrc is null) {
            return;
        }
        
        bagSrc.mergePerElementInto(next);
        
        // everything is merged!
        // Linearize movement of heaps by nulling reference
        ptr.bag.atomicStore(null);
    }
    
    /+
    Attempts to change *loc to dest while *loc has a higher id than dest
    +/
    static void ensureMovedDownTo(shared(Node*)* loc, shared(Node)* dest)
    in {
        assert(loc !is null);
        assert(dest !is null);
    }
    out {
        assert(loc !is null);
    }
    body {
        immutable id = dest.id;
        
        while(true) {
            shared(Node)* cur = atomicLoad(*loc);
            
            assert(cur !is null);
            
            if (cur is dest || cur.id < id) {
                // already done
                break;
            }
            else if (my_cas(loc, cur, dest)) {
                // succeeded in moving downwards
                break;
            }
            else {
                // another thread moved loc down, don't know yet if far enough
            }
        }
    }
    
    /+
    Moves ptr to point to the closest node with a non-null bag and returns the bag found there
    +/
    auto findClosestBag_noCompress()
    in { assert(ptr !is null); }
    out(bag) { assert(ptr !is null); assert(bag !is null); }
    body {
        while(true) {
            assert(ptr !is null);
            
            shared(Bag)* curBag = ptr.bag.atomicLoad; // last exec of this line == linearization point ???
            
            if (curBag !is null) {
                // found a bag!
                return curBag;
            }
            else {
                // cur's bag was merged into a descendent
                shared(Node)* next = ptr.next.atomicLoad; // ok because bag's atomicLoad
                
                // thus there must exist a descendent
                assert(next !is null);
                assert(ptr.id > next.id);
                
                // go to next node
                ptr = next;
            }
        }
        assert(false);
    }
    
package:
    void ensureMerged() {
        if (ptr is null) {
            return;
        }
        auto next = ptr.next.atomicLoad;
        
        if (next !is null) {
            ensureMergedInto(Handle(next));
        }
    }
    
    /+
    finds closest bag AND move down ptr
    +/
    auto findClosestBag()
    in { assert(ptr !is null); }
    out(bag) { assert(ptr !is null); assert(bag !is null); }
    body {
        shared(Node)* start = ptr;
        
        auto bag = findClosestBag_noCompress();
        
        assert(ptr !is null);
        
        while(start.id > ptr.id) {
            shared(Node)* next = start.next.atomicLoad;
            
            ensureMovedDownTo(&start.next, ptr);
            
            start = next;
        }
        
        return bag;
    }
    
    /+
    Returns false if handle points directly to an unmerged bag
    Returns true if handle is null or pointed to a merged bag (thus set to null)
    +/
    @property
    bool isFullyMerged() shared {
        auto cur = ptr.atomicLoad;
        if (cur is null) {
            return true;
        }
        else if (null is cur.bag.atomicLoad) {
            ptr.atomicStore(null);
            return true;
        }
        else {
            return false;
        }
    }
    
    /+
    Checks whether the handles' bags are mergable
    Assumes that if any two bags are mergable, then other merges will preserve that
    +/
    bool canMergeWith(ref Handle other) {
        return findClosestBag().canMergeWith( other.findClosestBag() );
    }
    
public:
    /++
    GC allocates a new Node and returns a Handle to it.
    Params:
    id = Unique identifier for the given Bag
    bagArgs = Arguments to the Bag constructor.
    Returns: A Handle to the created Node refering to the new Bag.
    +/
    static Handle make(BagArgs...)(size_t id, BagArgs bagArgs) {
        auto n = new shared Node(null, null, id);
        n.bag = new Bag(Handle(n), bagArgs);
        return Handle(n);
    }
    
    /++
    Returns: The total number of bytes that will be requested to the allocator
    when creating a new, empty instance of this type. The Args a are forwarded
    to Bag.fixedAllocSize to determine the result.
    +/
    static size_t fixedAllocSize(Args...)(Args a) {
        //pragma(msg, "Node.sizeof = " ~ Node.sizeof.stringof);
        
        return Node.sizeof + Bag.fixedAllocSize(a);
    }
    /++
    Static factory method which uses Alloc to allocate a new Node and returns a
    Handle to it.
    Params:
    id = Unique identifier for the given Bag
    bagArgs = Arguments to the Bag constructor.
    Returns: A Handle to the created Node refering to the new Bag.
    +/
    static Handle makeWith(Alloc, BagArgs...)(size_t id, BagArgs bagArgs) {
        void* nMem = Alloc.alloc(Node.sizeof).ptr;
        
        assert((cast(size_t)nMem) % Node.alignof == 0);
        
        // id is immutable thus must assign before casting to Node
        * cast(size_t*)(nMem + Node.id.offsetof) = id;
        
        auto n = cast(shared(Node)*) nMem;
        assert(n.id == id);
        n.next = null;
        n.bag = null;
        
        n.bag = Bag.makeWith!Alloc(Handle(n), bagArgs);
        
        return Handle(n);
    }
    
    /++
    Atomically loads a shared Handle.
    Returns: An unshared Handle refering to the same Bag that the shared Handle
    referred to at some point during the call.
    Progress: Wait-free
    +/
    @property
    Handle unshared() shared {
        return Handle(ptr.atomicLoad);
    }
    
    /++
    Attempt to move this shared handle down the chain to skip over merged nodes.
    
    This is for optimization only and has no semantic effects.
    
    Returns: true if this thread reaches an unmerged node,
    else false if another thread modified the handle concurrently.
    
    Progress: Lock-free, but wait-free if number of total merges is bounded.
    +/
    bool update() shared {
        auto cur = ptr.atomicLoad;
        
        if (cur is null) {
            return true;
        }
        
        while(true) {
            if (null !is cur.bag.atomicLoad) {
                return true;
            }
            
            auto next = cur.next.atomicLoad; 
            
            assert(next !is null);
            assert(cur.id > next.id);
            
            if (!my_cas(&ptr, cur, next)) {
                return false;
            }
            
            cur = next;
        }
        assert(false);
    }
    
    /++
    Returns: The id of the currently-referred Node.
    Progress: Wait-free.
    +/
    @property
    size_t id() in { assert(ptr !is null); } body {
        return ptr.id;
    }
    /++
    Returns: The id of a Node which this referred to at some point during the
    call.
    Progress: Wait-free.
    +/
    @property
    size_t id() shared {
        return unshared.id;
    }
    
    /++
    Returns: The width of the currently-referred Node's Bag. 
    Progress: Lock-free.
    +/
    @property
    size_t width() in { assert(ptr !is null); } body {
        return findClosestBag().width;
    }
    /++
    Returns: The width of the currently-referred Node's Bag.
    Progress: Lock-free.
    +/
    @property
    size_t width() shared {
        return unshared.width;
    }
    
    /++
    Atomically applies dg to some element of the Bag.
    Progress: Lock-free if there are no more than width total concurrent threads,
    otherwise deadlock-free.
    +/
    void apply(scope void delegate(Obj*) dg) shared {
        applyUntil((Obj* t) {
            dg(t);
            return true;
        });
    }
    
    /++
    Applies dg to elements in Bags which this Handle refers to during this call
    until dg returns true for the first time.
    
    If dg does not mutate when it returns false, then applyUntil is linearizable
    to a single application of dg which returns true.
    
    Warning: The applications of dg are NOT collectively atomic; merges and
    other calls to applyUntil may take affect on elements between calls to dg.
    To build a linearizable data structure using Handle, each time dg returns
    false, dg should NOT modify the element through the pointer or store
    information about the state of the element during that application, as if
    dg is a transaction which failed and must roll-back. However, dg may modify
    external state to keep track on the number of applications, for example.
    
    Progress: Lock-free if
    
    1. there are no more than width total concurrent threads,
    
    2. dg does not semantically modify through its argument if it returns false,
    and
    
    3. dg returns true after a finite number of applications.
    
    If only 2 and 3 hold, then this method is deadlock-free. Otherwise, no
    progress is guaranteed.
    +/
    void applyUntil(scope bool delegate(Obj*) dg) shared {
        scope(success) update();
        
        auto cur = unshared;
        while(true) {
            if(cur.findClosestBag().tryApplyUntil(dg) ) {
                break;
            }
        }
    }
    static if (hasMember!(Bag, "tryApplyUntil_2")) {
        void applyUntil_2(scope bool delegate(Obj*,Obj*) dg) shared {
            scope(success) update();
            
            auto cur = unshared;
            while(true) {
                if( cur.findClosestBag().tryApplyUntil_2(dg) ) {
                    break;
                }
            }
        }
    }
    /++
    Calls tryApplyEachUntil(dg) on the Bag this Handle references and
    returns the result.
    
    Progress: minimum of Lock-free and the progress of Bag.tryApplyEachUntil.
    +/
    bool tryApplyEachUntil(scope bool delegate(Obj*) dg) shared {
        scope(success) update();
        
        return unshared.findClosestBag().tryApplyEachUntil(dg);
    }
    
    /++
    Attempts to merge the elements in this and other's Bags together.
    Returns: MergeResult describing what occurred.
    Progress: Lock-free if there are no more than width total concurrent threads,
    otherwise deadlock-free.
    +/
    MergeResult mergeInto(ref Handle other) {
        // get local copies to use
        alias a = this;  //Handle(ptr.atomicLoad);
        alias b = other; //Handle(other.ptr.atomicLoad);
        
        assert(a.ptr !is null);
        assert(b.ptr !is null);
        
        if (! a.canMergeWith(b)) {
            return MergeResult.Incompatible;
        }
        
        // try to link other and this
        auto result = tryUnion(a, b);
        
        if (! result.merged ) {
            return MergeResult.IdClash;
        }
        if (result.dest.ptr is null) {
            return MergeResult.WereAlreadyEqual;
        }
        if (a != result.dest) {
            a.ensureMergedInto(b);
        }
        else {
            b.ensureMergedInto(a);
        }
        
        return MergeResult.Success;
    }
}

