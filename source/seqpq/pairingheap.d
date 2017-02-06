module mergearray.seqpq.pairingheap;

/++
A sequential Pairing Heap implementation of a priority queue of elements T using
allocator Alloc.
+/
struct PairingHeap(T, Alloc) {
private:
    struct Node {
        Node* child;
        Node* next;
        T value = void;
        
        this(T t) {
            value = t;
        }
        
        static auto merge(Node* a, Node* b) pure
        in {
            assert(a is null || a.next is null);
            assert(b is null || b.next is null);
        }
        body {
            if (a is null) {
                return b;
            }
            if (b is null) {
                return a;
            }
            
            if (a.value > b.value) {
                import std.algorithm;
                swap(a, b);
            }
            
            b.next = a.child;
            a.child = b;
            
            return a;
        }
    }
    
    static struct NodeRange {
        Node* front;
        void popFront() { front = front.next; }
        @property bool empty() const { return front is null; }
        @property NodeRange save() { return this; }
    }
    
    void mergeReduce() {
        if (head is null) {
            return;
        }
        
        if (head.child is null) {
            return;
        }
        
        // optimized/inlined to the same code in deleteMin ???
        enum UseRecursion = true;
        
        static if (UseRecursion) {
            Node* rec(NodeRange r) pure {
                if (r.empty) {
                    return null;
                }
                auto first = r.front;
                r.popFront();
                
                if (r.empty) {
                    return first;
                }
                auto second = r.front;
                r.popFront();
                
                first.next = null;
                second.next = null;
                
                return Node.merge(Node.merge(first, second), rec(r));
            }
            
            head.child = rec(NodeRange(head.child));
        }
        else {
            Node* acc = null;
            NodeRange r = NodeRange(head.child);
            
            while(true) {
                if (r.empty) {
                    break;
                }
                auto first = r.front;
                r.popFront();
                
                if (r.empty) {
                    acc = Node.merge(acc, first);
                    break;
                }
                auto second = r.front;
                r.popFront();
                
                first.next = null;
                second.next = null;
                
                acc = Node.merge(acc, Node.merge(first, second));
            }
            
            head.child = acc;
        }
    }
    
    Node* head;
    size_t size = 0;
    
public:
    /++
    The number of bytes allocated per element inserted.
    +/
    enum size_t NodeSize = Node.sizeof;
    
    /++
    Property returning true if and only if the container has no elements.
    Complexity: O(1)
    +/
    @property
    bool empty() const {
        return head is null;
    }
    /++
    Returns the number of elements in the container.
    Complexity: O(1)
    +/
    @property
    size_t length() const {
        return size;
    }
    
    /++
    Inserts t into the container.
    Complexity: O(1)
    +/
    void insert(T t) {
        size++;
        
        Node* n = Alloc.alloc!Node(t);
        
        head = Node.merge(head, n);
    }
    
    import std.typecons : Nullable;
    /++
    Removes the element with the minimum value.
    Complexity: O(log n)
    +/
    Nullable!T deleteMin() {
        mergeReduce();
        
        if (empty) {
            return Nullable!T();
        }
        else {
            auto t = Nullable!T(head.value);
            head = head.child;
            
            size--;
            
            return t;
        }
    }
    
    /++
    Returns the minimum element of the container.
    Complexity: O(1)
    +/
    @property
    Nullable!T peekMin() {
        if (empty) {
            return Nullable!T();
        }
        else {
            return Nullable!T(head.value);
        }
    }
    
    /++
    Steals the elements of other and inserts them (in bulk) into this container.
    
    Other is left empty.
    
    Complexity: O(1)
    +/
    void mergeSteal(ref PairingHeap other) {
        head = Node.merge(head, other.head);
        other.head = null;
        
        size += other.size;
        other.size = 0;
    }
}
