# Lem Mailbox


This is an ANSI CL adaptation from the SBCL Mailbox utility, it has been tested only in ABCL for now, but it should work on any ANSI CL implementation.

## Requirements
- bordeaux-threads 
- bt-semaphore 
- queues


## Installation

```lisp
(ql:quickload :lem-mailbox)

```


## Usage

The usage should be similar to the version in SBCL [mailbox](https://www.sbcl.org/manual/index.html#Mailbox-_0028lock_002dfree_0029)
