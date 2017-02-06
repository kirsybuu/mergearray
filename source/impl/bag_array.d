module mergearray.impl.bag_array;

// lockfree merge implementation

import core.atomic, core.sync.mutex, std.typecons, std.traits;

import mergearray.impl.header;
import mergearray.impl.handle_array;

////////////////////////////////////////////////////////////////////////////////

debug(mergearray_printactions) {
    import std.stdio : writefln;
}

private mixin template IntrusiveSList() {
    private static shared(typeof(this)) nil_value, dummyNodeIndicator_value;
    private enum nil = &nil_value;
    private enum dummyNodeIndicator = &dummyNodeIndicator_value;
    
    private shared(typeof(this))* iSListMyHead;
    private shared(typeof(this))* iSListUpperNext;
}

/++
An array-based implementation of a Bag for use by a Handle.
+/
struct MergeArray(Obj) if (is(Obj == struct) && !is(Obj == shared)) {
    /++
    The type of the contained sequential data structure.
    +/
    alias ElementType = Obj;
    
    /++
    The type of Handle which MergeArray expects to be underneath.
    +/
    alias H = Handle!(shared MergeArray);
    
private:
    enum RemoveDummyNodes = true;
    
    align(64)
    static struct Node {
        CoarseLocked!Obj elem = void;
        alias elem this;
        
        mixin IntrusiveSList mergeList; // list of pending merged Nodes
        
        Node* parent = null;
        
        enum UseTailSkip = true;
        
        static if (UseTailSkip) {
            Node* iSListUpperSkip;
        }
        
        H myhandle;   // the union-find node which this was created for
        
        this(ObjArgs...)(H h, ObjArgs args) shared {
            myhandle = h;
            elem = shared CoarseLocked!Obj(Obj(args));
            
            iSListMyHead = nil;
            iSListUpperNext = nil;
            
            static if (UseTailSkip) {
                iSListUpperSkip = nil;
            }
        }
        
        // returns false if this node's bag has been
        // merged as the source into another bag (linearized)
        @property
        bool wasMerged() shared {
            if (! isOwned) {
                return false;
            }
            else if (iSListMyHead.atomicLoad is null) {
                return true;
            }
            else {
                return myhandle.isFullyMerged;
            }
        }
        
        @property
        bool isOwned() shared {
            return parent.atomicLoad !is null;
        }
        bool ownedBy(shared(Node)* n) shared {
            auto p = parent.atomicLoad;
            
            if (p is null) {
                // cur was inserted into this list (and maybe others)
                // but not marked thus try to claim it
                if (my_cas(& parent, cast(shared(Node)*) null, n)) {
                    // was the thread which
                    debug(mergearray_printactions) writefln("%s: Made %x own %x", tid, n, &this);
                    
                    return true;
                }
                else {
                    p = parent.atomicLoad;
                }
            }
            
            return p is n;
        }
        
        //----------------------------------------------------------------------
        
        @property
        bool isNormal() shared in {
            assert(&this !is dummyNodeIndicator);
            assert(&this !is null);
        } body {
            return &this !is nil;
        }
        
        bool isAppendableTail(shared(Node)* cur) shared {
            return !cur.isNormal || !cur.ownedBy(&this);
        }
        
        auto listContinuesAfter(shared(Node)* cur) shared {
            if (!isAppendableTail(cur)) {
                auto next = cur.iSListUpperNext.atomicLoad;
                
                assert(next !is null);
                
                if (next !is dummyNodeIndicator) {
                    return next;
                }
            }
            return null;
        }
        
        void listFindEnd(ref shared(Node)* prev, ref shared(Node)* cur) shared {
            static if (UseTailSkip) {
                // heuristic shortcut to end of list
                auto skip = prev.iSListUpperSkip.atomicLoad;
                
                while (skip !is nil) {
                    // prev is at least two nodes away from the end of the list
                    assert(! isAppendableTail(skip));
                    
                    auto further = skip.iSListUpperSkip.atomicLoad;
                    
                    if (further is nil) {
                        // skip is near the end of the list, go to slow search
                        cur = prev.iSListUpperNext.atomicLoad;
                        break;
                    }
                    else {
                        // skip is in the middle of the skip list, compress and keep going
                        my_cas(& prev.iSListUpperSkip, skip, further);
                        prev = skip;
                        skip = further;
                    }
                }
                // got to the end of the skip list
            }
            
        slowSearch:
            {
                // O(n) search for the end of the list
                while(true) {
                    if (auto next = listContinuesAfter(cur)) {
                        static if (UseTailSkip) {
                            if (prev.iSListUpperSkip.atomicLoad is nil) {
                                my_cas(& prev.iSListUpperSkip, nil, cur);
                            }
                        }
                        prev = cur;
                        cur = next;
                    }
                    else break;
                }
            }
        }
        
        //----------------------------------------------------------------------
        
        enum EvalMergeStatus { NoMergesLeft, SomeMergesLeft, LockFreeBailout }
        static struct EvalMergeResult {
            Flag!"ShouldBailout" bailout;
        }
        
        // loop over each node in my merge list and merge elems
        // at the point of return, the merge list is empty
        EvalMergeResult evalMerges_locked(Obj* rootElem, shared(Node)* newHead = nil, ptrdiff_t conditionOffset = 0) shared
        in { assert(newHead is nil || newHead is null); }
        body {
            bool stop = false;
            
            with(EvalMergeStatus)
            while(! stop) {
                shared(Node)* cur = mergeList.iSListMyHead.atomicLoad;
                
                auto firstHead = cur;
                
                stop = cur is newHead;
                
                if (stop) break;
                
                assert(cur !is null);
                assert(cur !is dummyNodeIndicator);
                
                if (null is listContinuesAfter(cur)) {
                    // remove cur from the list, which is thus empty
                    stop = my_cas(& iSListMyHead, cur, newHead);
                    
                    debug(mergearray_printactions) writefln("%s: Cleared head %x of %x", tid, cur, &this);
                    
                    continue;
                }
                
                if (cur.iSListMyHead.atomicLoad is null) {
                    // cur has been inserted then deleted before
                    stop = my_cas(& iSListMyHead, cur, newHead);
                    
                    debug(mergearray_printactions) writefln("%s: Cleared head %x of reinserted %x", tid, cur, &this);
                    
                    continue;
                }
                
                while(cur !is nil) {
                    assert(cur !is null);
                    assert(cur !is dummyNodeIndicator);
                    assert(cur.isOwned && cur.ownedBy(&this));
                    
                    assert(cur is iSListMyHead.atomicLoad);
                    assert(dummyNodeIndicator !is cur.iSListUpperNext.atomicLoad);
                    
                    if (cur.iSListMyHead.atomicLoad is null) {
                        // "duplicate" node due to multiple threads succeeding at inserting cur into lists
                        // cur was previously deleted, so just need to remove from list
                        
                        assert(false);
                    }
                    else {
                        // cur must be marked deleted and have its elem merged into this's elem
                        
                        // ensure that cur is linearized to be inserted into this bag
                        cur.myhandle.unshared.ensureMerged();
                        
                        // at this point:
                        // cur.isFullyMerged = true (linearized)
                        // if any thread starts trying to insert to cur.mergeList, it will fail and try to insert into my list
                        
                        bool bailout = false;
                        
                        bool gotLock = cur.tryLocked((Obj* subElem) {
                            /+
                            since cur is locked and cur's merge is linearized, its list
                            can only be appended to at most once by each other thread
                            +/
                            EvalMergeResult subResult = cur.evalMerges_locked(subElem, null);
                            
                            if (subResult.bailout) {
                                // bailed out because of lock contention
                                // subElem is not guaranteed to be in a linearized state,
                                // thus follow suit and propogate bailout
                                bailout = true;
                                return;
                            }
                            
                            rootElem.mergeSteal(*subElem);
                        });
                        
                        if (bailout || !gotLock) {
                            // abort the operation
                            return EvalMergeResult(Yes.ShouldBailout);
                        }
                    }
                    
                    assert(cur.iSListMyHead.atomicLoad is null);
                    
                    size_t iter = 0;
                    
                removeCur:
                    
                    iter++;
                    
                    assert(cur is iSListMyHead.atomicLoad);
                    
                    // cur is the head of mergeList, thus to remove, only need to redirect head to next
                    auto next = cur.iSListUpperNext.atomicLoad;
                    
                    assert(next !is null);
                    
                    assert(next !is dummyNodeIndicator);
                    
                    if (! isAppendableTail(next)) {
                        // list has more elements
                        
                        assert(iSListMyHead.atomicLoad is cur);
                        
                        assert(next !is dummyNodeIndicator);
                        
                        //iSListMyHead.atomicStore(next);
                        if (my_cas(& iSListMyHead, cur, next)) {
                            // successfully removed cur
                            debug(mergearray_printactions) writefln("%s: Deleted %x under %x, was head of nonempty list", tid, cur, &this);
                            
                            cur = next;
                        }
                        else {
                            // should be impossible to get here ???
                            debug(mergearray_printactions) writefln("%s: Failed to delete %x under %x, was head of nonempty list!!!!!!!!", tid, cur, &this);
                            
                            assert(false, "MergeArray Error: Failed to delete head of non-empty list.");
                        }
                    }
                    else {
                        // list has no other elements, thus another thread may insert a new node at next
                        
                        // set next to dummyNodeIndicator so other threads will try to replace cur
                        // rather than cur's next slot
                        
                        assert(iSListMyHead.atomicLoad is cur);
                        
                        assert(next !is dummyNodeIndicator);
                        
                        if (my_cas(& cur.iSListUpperNext, next, dummyNodeIndicator)) {
                            // succeeded in marking cur as a removable node
                            
                            debug(mergearray_printactions) {
                                writefln("%s: Marked %x as dummy under %x", tid, cur, &this);
                            }
                            
                            static if (RemoveDummyNodes) {
                                // now try to remove cur from myhead if another thread hasn't yet
                                stop = my_cas(& iSListMyHead, cur, newHead);
                                
                                // at this point, iSListMyHead must not be equal to cur and never will again
                                debug(mergearray_printactions) writefln("%s: Dummy %x was removed from under %x", tid, cur, &this);
                            }
                            else {
                                // let another thread clean it up
                                stop = true;
                            }
                            
                            break;
                        }
                        else {
                            // another thread appended to cur, so remaining list is not empty anymore
                            
                            
                            goto removeCur;
                        }
                    }
                }
            }
            return EvalMergeResult(No.ShouldBailout);
        }
        
        // resolves all lazy merges in myMergeHead which have been linearized
        // then applies dg to this node's elem
        //
        enum EvalApplyResult { Finished, NextElem, NextBag }
        
        auto tryEvalMergesAndApply(scope bool delegate(Obj*) dg, ptrdiff_t conditionOffset = 0) shared {
            EvalApplyResult result = EvalApplyResult.NextElem;
            
            bool gotLock = tryLocked((Obj* myElem) {
                
                if (wasMerged) {
                    // should abandon this bag
                    result = EvalApplyResult.NextBag;
                    return;
                }
                
                // try to evaluate lazy merges which are linearized before
                bool retry = evalMerges_locked(myElem, nil, conditionOffset).bailout;
                
                if (retry) {
                    // detected contention thus retry on a different elem
                    return;
                }
                
                if (wasMerged) {
                    // should abandon this bag
                    result = EvalApplyResult.NextBag;
                    return;
                }
                
                // perform operation on current state of the elem
                if ( dg(myElem) ) {
                    result = EvalApplyResult.Finished;
                }
            });
            
            return result;
        }
    }
    
    Node[] nodes;
    
    // randomly distributed infinite range over [0,width)
    @property
    auto randomIndexRange() shared {
        import std.random, std.range;
        size_t start = uniform!"[)"(cast(size_t) 0, width);
        return iota(0, width).cycle().dropExactly(start);
    }
    
public:
    /++
    Construct a new MergeArray, allocating on the GC heap.
    Params:
    parent = The Handle which this is being created for.
    width = The size of the internal Obj[].
    args = Arguments for the constructor of each Obj.
    +/
    this(ObjArgs...)(H parent, size_t width, ObjArgs args) shared {
        nodes = new shared Node[](width);
        
        foreach(ref n ; nodes) {
            n = shared Node(parent, args);
        }
    }
    
    /++
    Returns: The total number of bytes that will be requested to the allocator
    when creating a new instance of this type.
    +/
    static size_t fixedAllocSize(size_t width) {
        //pragma(msg, "MergeArray.sizeof + Node.sizeof * width = " ~ MergeArray.sizeof.stringof ~ " + " ~ Node.sizeof.stringof ~ " * width");
        
        return MergeArray.sizeof + Node.sizeof * width;
    }
    /++
    Static factory method using Alloc to allocate a new shared MergeArray.
    Params:
    parent = The Handle which this is being created for.
    width = The size of the internal Obj[].
    args = Arguments for the constructor of each Obj.
    Returns: A pointer to the new shared MergeArray.
    +/
    static shared(MergeArray)* makeWith(Alloc, ObjArgs...)(H parent, size_t width, ObjArgs args) {
        auto nodesptr = (cast(shared(Node)*) Alloc.alloc(Node.sizeof * width).ptr);
        
        assert((cast(size_t)nodesptr) % shared(Node).alignof == 0);
        
        auto self = cast(shared(MergeArray)*) Alloc.alloc(MergeArray.sizeof).ptr;
        
        assert((cast(size_t)self) % shared(MergeArray).alignof == 0);
        
        self.nodes = nodesptr[0 .. width];
        
        foreach(ref n ; self.nodes) {
            n = shared Node(parent, args);
        }
        return self;
    }
    
    /++
    Returns: The number of Obj in the internal array. This is a constant.
    +/
    @property
    size_t width() shared {
        return nodes.length;
    }
    
    /++
    Tests whether or not this is merge-compatible (has the same width) as other.
    Returns: width == other.width
    +/
    bool canMergeWith(shared(MergeArray)* other) shared {
        return width == other.width;
    }
    
    /++
    Merges all Objs in this MergeArray into the MergeArray referenced by dest.
    
    Each individual Obj merge is only performed once by any thread.
    +/
    void mergePerElementInto(H dest) shared {
        import std.algorithm, std.range;
        
        auto indices = randomIndexRange().takeExactly(width);
        
        shared(Node)* prevDummy = null;
        
    getDestBag:
        auto destBag = dest.findClosestBag();
        
    indicesLoop:
        while(!indices.empty) {
            immutable i = indices.front;
            auto srcNode = & nodes[i];
            
            if (srcNode.wasMerged) {
                return;
            }
            auto destNode = & destBag.nodes[i];
            
            enum nil = Node.nil;
            enum dummyNodeIndicator = Node.dummyNodeIndicator;
            
            //------------------------------------------------------------------
            
            bool tryInsert(shared(Node*)* loc, shared(Node)* expected, string reason) {
                if (srcNode.isOwned) {
                    // another thread inserted srcNode into the list already
                    // go to next srcNode
                    indices.popFront();
                    return true; // continue indicesLoop;
                }
                
                if (my_cas(loc, expected, srcNode)) {
                    // succeeded at inserting
                    
                    debug(mergearray_printactions) {
                        writefln("%s: Inserted %x under %x at %x, was %x (%s)", tid, srcNode, destNode, loc, expected, reason);
                    }
                    
                    if (srcNode.ownedBy(destNode)) {
                        // marked destNode as the "true" owner of srcNode
                        debug(mergearray_printactions) writefln("%s: %x owns newly-inserted %x", tid, destNode, srcNode);
                    }
                    else {
                        // srcNode was already claimed by another bag
                        
                        // undo the double insert and go to next srcNode
                        my_cas(loc, srcNode, nil);
                        
                        debug(mergearray_printactions) writefln("%s: Failed to make %x own %x", tid, destNode, srcNode);
                    }
                    
                    // go to next srcNode
                    indices.popFront();
                    return true;
                }
                
                return false;
            }
            
            //------------------------------------------------------------------
        curLoop:
            
            shared(Node)* first = destNode.iSListMyHead.atomicLoad;
            assert(first !is dummyNodeIndicator);
            
            if (first is null) {
                // destNode was linearized merged and removed
                goto getDestBag;
            }
            
            if (first is srcNode) {
                // found it already in the list, so don't 
                bool gotit = srcNode.ownedBy(destNode);
                
                debug(mergearray_printactions) writefln("%s: Found %x at head of %x list (ownedBy == %s)", tid, srcNode, destNode, gotit);
                
                indices.popFront();
                continue indicesLoop;
            }
            
            if (auto second = destNode.listContinuesAfter(first)) {
                // must insert srcNode at the tail of nonempty list
                
                shared(Node)* prev = first;
                shared(Node)* cur = second;
                
            recLoop:
                destNode.listFindEnd(prev, cur);
                
                if (destNode.isAppendableTail(cur)) {
                    // prevAddr can be rewritten from cur to srcNode
                    if (tryInsert(& prev.iSListUpperNext, cur, "tail")) {
                        // srcNode has been inserted somewhere
                        continue indicesLoop;
                    }
                    else {
                        // some other thread modified it first, so read it again
                        cur = prev.iSListUpperNext.atomicLoad;
                        if (cur !is dummyNodeIndicator) {
                            // prev now points to nil or some other node
                            // just try again
                            goto recLoop;
                        }
                        else {
                            // prev is now a dummy node, can't append to it
                            // must start/continue another merge list
                        }
                    }
                }
                else {
                    // cur is a dummy node, can't append to it
                    assert(cur.iSListUpperNext.atomicLoad is dummyNodeIndicator);
                }
                
                // list ends in a dummy node thus isn't valid for appending
                
                auto newHead = destNode.iSListMyHead.atomicLoad;
                
                if (newHead is first) {
                    // head hasn't changed since we read first and second, thus
                    // the dummy node is illegally at the end of a list,
                    // so first must have been deleted and re-inserted
                    
                    assert(first.iSListMyHead.atomicLoad is null);
                    
                    if (tryInsert(& destNode.iSListMyHead, first, "head")) {
                        // srcNode has been inserted somewhere
                        continue indicesLoop;
                    }
                    else {
                        // some other thread modified head
                        goto curLoop;
                    }
                }
                else {
                    // list has been updated so the dummy node may not be illegal
                    goto curLoop;
                }
            }
            else {
                // can insert srcNode directly at head of empty list
                if (tryInsert(& destNode.iSListMyHead, first, "head")) {
                    // srcNode has been inserted somewhere
                    continue indicesLoop;
                }
                else {
                    // some other thread modified head
                    goto curLoop;
                }
            }
        }
    }
    
    /+
    Applies dg to elements in the array until dg returns true (thus this does too)
    or this bag is fully merged before then (thus this returns false)
    +/
    bool tryApplyUntil(scope bool delegate(Obj*) dg) shared {
        foreach(immutable i ; randomIndexRange) {
            immutable result = nodes[i].tryEvalMergesAndApply(dg);
            
            with(Node.EvalApplyResult)
            final switch(result) {
                case Finished: return true;
                case NextElem: continue;
                case NextBag : return false;
            }
            assert(false);
        }
        assert(false);
    }
    
    /++
    Applies dg to each element in cyclic fashion until it returns true or the
    MergeArray is disrupted by a merge.
    
    dg is applied to each element in turn, such that once dg is applied to an
    element, it is not reapplied to the same element until width-1 other
    applications of dg finished and all returned false.
    
    If this is merged with another MergeArray with a lower Handle id, such that
    the Objs in this are mergeSteal'd from, then the further applications of dg
    will stop.
    
    Warning: The applications of dg are NOT collectively atomic, only
    individually atomic.
    
    Progress: Deadlock-free if dg returns true after a finite number of
    applications.
    
    Returns: true if an application of dg returns true, or false if this was
    merged into another MergeArray before dg could return true.
    +/
    bool tryApplyEachUntil(scope bool delegate(Obj*) dg) shared {
        with (Node.EvalApplyResult)
        foreach(immutable i ; randomIndexRange) {
            auto result = NextElem;
            auto srcNode = & nodes[i];
            
            srcNode.locked((Obj* myElem) {
                if (srcNode.wasMerged) {
                    // should abandon this bag
                    result = NextBag;
                    return;
                }
                
                // evaluate lazy merges which are linearized before
                srcNode.evalMerges_locked(myElem);
                
                if (srcNode.wasMerged) {
                    // should abandon this bag
                    result = NextBag;
                    return;
                }
                
                // perform operation on current state of the elem
                if ( dg(myElem) ) {
                    result = Finished;
                }
            });
            
            final switch(result) {
                case Finished: return true; // dg returned true
                case NextElem: continue;    // dg returned false
                case NextBag : return false;// bag was Merged
            }
            assert(false);
        }
        assert(false);
    }
}

