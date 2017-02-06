module mergearray.seqpq.skewheap;

/++
A sequential Skew Heap implementation of a priority queue of elements T using
allocator Alloc.
+/
struct SkewHeap(T, Alloc) {
private:
    struct Node {
        Node* left = null;
        Node* right = null;
        T value = void;
        
        this(T t) {
            value = t;
        }
    }
    
    Node* head = null;
    size_t size = 0;
    
    static Node* merge(Node* a, Node* b) {
        enum useRecursion = true;
        
        static if (useRecursion) {
            static join(Node* x, Node* y) {
                auto l = x.left;
                x.left = x.right;
                x.right = merge(l, y);
                return x;
            }
            
            if (a is null) {
                return b;
            }
            else if (b is null) {
                return a;
            }
            else if (a.value < b.value) {
                return join(a,b);
            }
            else {
                return join(b,a);
            }
            
            assert(false);
        }
        else {
            Node* root = null;
            Node** result = &root;
            
            while(true) {
                if (a is null) {
                    *result = b;
                    break;
                }
                else if (b is null) {
                    *result = a;
                    break;
                }
                
                if (a.value >= b.value) {
                    import std.algorithm;
                    
                    swap(a,b);
                }
                
                *result = a;
                result = &a.right;
                
                auto l = a.left;
                a.left = a.right;
                a = l;
            }
            
            return root;
        }
    }
    
    void insert(Node* n) {
        size++;
        head = merge(head, n);
    }
    
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
    Complexity: O(log n)
    +/
    void insert(T t) {
        size++;
        
        Node* n = Alloc.alloc!Node(t);
        
        head = merge(head, n);
    }
    
    import std.typecons : Nullable;
    /++
    Removes the element with the minimum value.
    Complexity: O(log n)
    +/
    Nullable!T deleteMin() {
        if (empty) {
            return Nullable!T();
        }
        else {
            auto t = Nullable!T(head.value);
            
            Node* oldhead = head;
            
            head = merge(head.left, head.right);
            
            size--;
            
            return t;
        }
    }
    
    /++
    Returns the minimum element of the container.
    Complexity: O(1)
    +/
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
    
    Complexity: O(log n + log m), where m = other.length
    +/
    void mergeSteal(ref SkewHeap other) {
        head = merge(head, other.head);
        other.head = null;
        
        size += other.size;
        other.size = 0;
    }
}
