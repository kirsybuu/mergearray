/++
Copyright: Michael Coulombe 2016
License: The MIT License
+/
module mergearray;

import mergearray.impl.allocator;
import mergearray.seqpq.skewheap, mergearray.seqpq.pairingheap;
import std.typecons : Flag, Yes, No;

private struct Versioned(C) {
    C c;
    alias c this;
    
    size_t versionNumber = 0;
}

/++
A Relaxed Concurrent Mergeable Priority Queue.

PriorityQueue is a relaxed concurrent priority queue implementation which, under
the appropriate assumptions, supports lock-free insert and merge operations and
a deadlock-free remove-min. Any operation such that given p threads and width p, a
removed element is expected to have average rank p and worst-case rank
O(p log p).

Sequential Semantics: A PriorityQueue is an array of InnerPQ instances.
An insert and remove will randomly choose an index to atomically operate on, and
a PriorityQueue merge is an atomic, index-by-index merge of corresponding
InnerPQ instances.
+/
struct PriorityQueue(T,
                     Alloc = GCAllocator,
                     InnerPQ = SkewHeap!(T, Alloc) /+ PairingHeap!(T, Alloc) +/,
                     Flag!"EnableEmpty" EnableEmpty = No.EnableEmpty) {
private:
    
    static if (EnableEmpty) {
        alias SeqPQ = Versioned!InnerPQ;
    }
    else {
        alias SeqPQ = InnerPQ;
    }
    
    private import mergearray.impl.handle_array, mergearray.impl.bag_array;
    alias Bag = shared(MergeArray!SeqPQ);
    alias H = Handle!Bag;
    
    import std.traits : hasMember;
    enum TwoQueueBalanceInsert = false && hasMember!(H, "applyUntil_2");
    enum TwoQueueBalanceRemove = false && hasMember!(H, "applyUntil_2");
    
    H handle;
    
public:
    /++
    The element type of the priority queue
    +/
    alias ElementType = T;
    
    /++
    The total number of bytes that will be requested to the allocator in order
    to insert a single element (element size + overhead).
    +/
    enum size_t PerElemAllocSize = SeqPQ.NodeSize;
    
    /++
    Returns: The total number of bytes that will be requested to the allocator
    when creating a new, empty instance of this type with the given width.
    +/
    static size_t fixedAllocSize(size_t width) {
        return H.fixedAllocSize(width);
    }
    
    /++
    Construct a new PriorityQueue, which is a handle to width InnerPQs allocated
    using Alloc.
    Params:
        width = The number of InnerPQs.
        handleId = A unique identifier among PriorityQueues with the same width.
    +/
    this(size_t width, size_t handleId) shared {
        static if (is(Alloc == GCAllocator)) {
            handle = H.make(handleId, width);
        }
        else {
            handle = H.makeWith!Alloc(handleId, width);
        }
    }
    
    /++
    The width of the PriorityQueue.
    
    Returns: The number of InnerPQs held inside.
    +/
    @property
    size_t width() shared {
        return handle.width;
    }
    
    /++
    Inserts an element into one of the InnerPQs.
    
    The destination is chosen randomly among the InnerPQs that are not being
    operated on by other threads. Elements should be well-distributed under low
    contention, and also under high contention if the distribution of inserted
    elements is similar between threads.
    Params:
        t = The element to be inserted.
    Progress: Lock-free if there are no more than width total concurrent threads,
    otherwise deadlock-free.
    +/
    void insert(T t) shared {
        void dg(SeqPQ* sh) {
            sh.insert(t);
            
            static if (EnableEmpty) {
                sh.versionNumber++;
            }
        }
        
        static if (TwoQueueBalanceInsert) {
            if (handle.width > 1) {
                // heuristic: insert into heap with fewer elements
                handle.applyUntil_2((SeqPQ* first, SeqPQ* second) {
                    if (first.length <= second.length) {
                        dg(first);
                    }
                    else {
                        dg(second);
                    }
                    
                    return true;
                });
            }
            else {
                handle.apply(& dg);
            }
        }
        else {
            handle.apply(& dg);
        }
    }
    
    import std.typecons : Nullable;
    /++
    Attempts to remove an element from one of the InnerPQs up to maxRetries
    times.
    
    The source is chosen randomly among the InnerPQs that are not being
    operated on by other threads.
    With low contention, the expected rank of the removed element is width. With
    high contention, the expected average rank of concurrently-removed elements
    is width. The expected maximum rank is O(width log(width)).
    Returns: A removed element, or null if each attempt failed.
    Progress: Lock-free if there are no more than width total concurrent threads,
    otherwise deadlock-free.
    +/
    Nullable!T tryRemoveAny(const size_t maxRetries) shared {
        size_t retries = 0;
        
        Nullable!T finalResult;
        
        bool dg(SeqPQ* sh) {
            import std.typecons;
            
            auto result = sh.deleteMin();
            
            if (! result.isNull) {
                static if (EnableEmpty) {
                    sh.versionNumber++;
                }
                
                finalResult = result;
                return true;
            }
            else {
                retries++;
                return retries > maxRetries;
            }
        }
        
        static if (TwoQueueBalanceRemove) {
            if (handle.width > 1) {
                // heuristic: delete from heap with higher priority root
                handle.applyUntil_2((SeqPQ* first, SeqPQ* second) {
                    auto peekFirst = first.peekMin();
                    auto peekSecond = second.peekMin();
                    
                    if (peekSecond.isNull) {
                        return dg(first);
                    }
                    else if (peekFirst.isNull) {
                        return dg(second);
                    }
                    else if (peekFirst.get <= peekSecond.get) {
                        return dg(first);
                    }
                    else {
                        return dg(second);
                    }
                });
            }
            else {
                handle.applyUntil(& dg);
            }
        }
        else {
            handle.applyUntil(& dg);
        }
        
        return finalResult;
    }
    
    /++
    Removes an element from one of the InnerPQs.
    
    Slightly-more efficient than looping tryRemoveAny, but no way to bail out.
    Warning: This method is blocking: it will run forever if empty.
    Returns: A removed element.
    Progress: Deadlock-free if there are no more than width total concurrent threads.
    +/
    T removeAny() shared {
        T t;
        
        bool dg(SeqPQ* sh) {
            auto result = sh.deleteMin();
            
            if (! result.isNull) {
                static if (EnableEmpty) {
                    sh.versionNumber++;
                }
                
                t = result.get;
                return true;
            }
            else {
                return false;
            }
        }
        
        static if (TwoQueueBalanceRemove) {
            if (handle.width > 1) {
                // heuristic: delete from heap with higher priority root
                handle.applyUntil_2((SeqPQ* first, SeqPQ* second) {
                    auto peekFirst = first.peekMin();
                    auto peekSecond = second.peekMin();
                    
                    if (peekSecond.isNull) {
                        return dg(first);
                    }
                    else if (peekFirst.isNull) {
                        return dg(second);
                    }
                    else if (peekFirst.get <= peekSecond.get) {
                        return dg(first);
                    }
                    else {
                        return dg(second);
                    }
                });
            }
            else {
                handle.applyUntil(& dg);
            }
        }
        else {
            handle.applyUntil(& dg);
        }
        
        return t;
    }
    
    /++
    Searches for an empty InnerPQ and swaps it with src. Useful for efficient
    bulk initialization.
    Warning: This method is blocking: it will run forever if no InnerPQ is empty.
    +/
    void swapEmptyWith(ref InnerPQ src) shared {
        bool dg(SeqPQ* sh) {
            if (! sh.empty) {
                return false;
            }
            //*sh = src;
            //src = InnerPQ.init;
            import std.algorithm : swap;
            static if (EnableEmpty) {
                swap(sh.c, src);
            
                sh.versionNumber++;
            }
            else {
                swap(*sh, src);
            }
            return true;
        }
        
        handle.applyUntil(& dg);
    }
    
    static if (EnableEmpty) {
        /++
        Tests whether or not there are elements in any InnerPQ.
        
        Requires the EnableEmpty flag to be set to use this method. The flag
        incurs a width * size_t.sizeof overhead, and this method allocates
        width * size_t.sizeof internally to perform a snapshot.
        Returns: false if it finds any InnerPQ that is not empty, or true if it
        can determine that all InnerPQs are simultaneously empty.
        This value is relative to a linearization point during the call.
        
        Progress: Deadlock-free.
        +/
        bool empty() shared {
            bool isEmpty = false;
            size_t i;
            import std.container : Array;
            auto versions = Array!size_t();
            versions.length = handle.width;
            
            bool dg(SeqPQ* sh) {
                if (! sh.empty) {
                    return true;
                }
                else if (i < versions.length) {
                    versions[i] = sh.versionNumber;
                    i++;
                    return false;
                }
                else if (i < 2 * versions.length) {
                    const orig = i - versions.length;
                    
                    if (versions[orig] != sh.versionNumber) {
                        return true; // not a snapshot - wasn't empty at some point
                    }
                    else {
                        i++;
                        return false;
                    }
                }
                else {
                    // 2-pass snapshot of all empty heaps!
                    isEmpty = true;
                    return true;
                }
            }
            
            while(true) {
                i = 0;
                if (handle.tryApplyEachUntil(&dg)) {
                    break;
                }
            }
            
            return isEmpty;
        }
    }
    
    /++
    Attempts to merge this PriorityQueue with another of the same width.
    
    After a successful merge, this and other will both be handles refering to
    the same width InnerPQs, where the two original InnerPQs with the same
    [0,width-1] index will be merged to create the InnerPQ of that index in the
    result.
    Returns:
        MergeResult.Success if merge was successful.
        
        MergeResult.WereAlreadyEqual if merge was already performed.
        
        MergeResult.IdClash if two identical ids were found (should never allow to happen).
        
        MergeResult.Incompatible if widths of this and other are not equal.
    
    Progress: Lock-free.
    +/
    MergeResult merge(shared PriorityQueue other) shared {
        auto a = handle.unshared;
        auto b = other.handle.unshared;
        
        scope(success) {
            handle.update();
            other.handle.update();
        }
        
        return a.mergeInto(b);
    }
}
///
unittest {
    import std.range : iota;
    import std.parallelism : TaskPool;
    import core.sync.barrier : Barrier;
    enum numThreads = 4;
    auto b = new Barrier(numThreads);
    auto tp = new TaskPool(numThreads-1);
    // pq0 and pq1 are shared handles to priority queue data structures
    alias A = TLRegionAllocator;
    alias PQ = shared PriorityQueue!(int, A, SkewHeap!(int,A), Yes.EnableEmpty);
    PQ pq0, pq1;
    // for each thread in taskpool:
    foreach(id ; tp.parallel(iota(numThreads), 1)) {
        b.wait();
        // initialize allocator and construct priority queues
        A.enter(2 ^^ 12);
        if (id == 0) {
            pq0 = PQ(numThreads, 0);
            pq1 = PQ(numThreads, 1);
        }
        b.wait();
        // insert test values
        pq0.insert(id);
        pq1.insert(id + numThreads);
        // attempt to merge pq0 and pq1
        if (id % 2 > 0) {
            pq0.merge(pq1);
        }
        else {
            pq1.merge(pq0);
        }
        // remove all items
        while (! pq0.empty) {
            auto maybe_int = pq0.tryRemoveAny(10);
        }
        b.wait();
        // cleanup allocator
        A.exit();
    }
    // cleanup taskpool
    tp.finish(true);
}
