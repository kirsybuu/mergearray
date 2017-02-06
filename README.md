Merge Array
===========

Dub package for the Merge Array data structure, written in the D programming language.

Implements a concurrent, mergable priority queue with lock-free merge and insert and deadlock-free remove-min.

Dependencies
-------------

*   Phobos
*   std.experimental.allocator

Proofs
------

This dub package is the continuation of the work done for my Master's Thesis.

Proofs of correctness and details of guarantees can be found in the [thesis pdf](http://www.mit.edu/~mcoulomb/resources/sm.pdf).
