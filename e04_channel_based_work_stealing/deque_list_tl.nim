# A list-based thread-local work-stealing deque
# Tasks are stored in an unbounded doubly linked list

import
  # Internal
  ./primitives/c,
  ./task, ./task_stack

type
  DequeListTl = ptr DequeListTlObj
  DequeListTlObj = object
    head, tail: Task
    num_tasks: int32
    num_steals: int32
    # Pool of free task objects
    freelist: TaskStack

# Basic deque routines
# ---------------------------------------------------------------

func deque_list_tl_empty(dq: DequeListTl): bool {.inline.} =
  assert not dq.isNil
  result = (dq.head == dq.tail) and (dq.num_tasks == 0)

func deque_list_tl_num_tasks(dq: DequeListTl): int32 {.inline.} =
  assert not dq.isNil
  result = dq.num_tasks

func deque_list_tl_push(dq: DequeListTl, task: sink Task) =
  assert not dq.isNil
  assert not task.isNil

  task.next = dq.head
  dq.head.prev = task
  dq.head = task

  inc dq.num_tasks

func deque_list_tl_pop(dq: DequeListTl): Task =
  assert not dq.isNil

  if dq.deque_list_tl_empty():
    return nil

  result = dq.head
  dq.head = dq.head.next
  dq.head.prev = nil
  result.next = nil

  dec dq.num_tasks

func deque_list_tl_new(): DequeListTl =
  result = malloc(DequeListTlObj)
  if result.isNil:
    raise newException(OutOfMemError, "Could not allocate memory")

  let dummy = task_new()
  dummy.fn = cast[proc (param: pointer){.nimcall.}](ByteAddress 0xCAFE) # Easily assert things going wrong
  result.head = dummy
  result.tail = dummy
  result.num_tasks = 0
  result.num_steals = 0
  result.freelist = task_stack_new()

func deque_list_tl_delete(dq: sink DequeListTl) =
  if dq.isNil:
    return

  # Free all remaining tasks
  while (let task = dq.deque_list_tl_pop(); not task.isNil):
    task_delete(task)
  assert(deque_list_tl_num_tasks(dq) == 0)
  assert(deque_list_tl_empty(dq))
  # Free dummy node
  task_delete(dq.head)
  # Free cache
  task_stack_delete(dq.freelist)
  free(dq)

func deque_list_tl_prepend(
       dq: sink DequeListTl,
       head, tail: Task,
       len: int32
      ): DequeListTl =
  # Add a list of tasks [head, tail] of length len to the front of the dq
  assert not dq.isNil
  assert not head.isNil and not tail.isNil
  assert len > 0

  # Link tail with dq.head
  assert tail.next.isNil
  tail.next = dq.head
  dq.head.prev = tail

  # Update state of the deque
  dq.head = head
  dq.num_tasks += len

  return dq

func deque_list_tl_prepend(
       dq: sink DequeListTl,
       head: Task,
       len: int32
     ): DequeListTl =

  assert not dq.isNil
  assert not head.isNil
  assert len > 0

  var tail = head
  # Find the tail
  while not tail.next.isNil:
    tail = tail.next

  deque_list_tl_prepend(dq, head, tail, len)


# Task routines
# ---------------------------------------------------------------

func deque_list_tl_task_new(dq: DequeListTl): Task =
  assert not dq.isNil

  if dq.freelist.task_stack_empty():
    return task_new()
  return dq.freelist.task_stack_pop()

func deque_list_tl_pop_child(dq: DequeListTl, parent: Task): Task =
  assert not dq.isNil
  assert not parent.isNil

  if dq.deque_list_tl_empty():
    return nil

  result = dq.head
  if result.parent != parent:
    # Not a child, don't pop it
    return nil

  dq.head = dq.head.next
  dq.head.prev = nil
  result.next = nil

  dec dq.num_tasks

# Work-stealing routines
# ---------------------------------------------------------------

func deque_list_tl_steal(dq: DequeListTl): Task =
  assert not dq.isNil

  if dq.deque_list_tl_empty():
    return nil

  result = dq.tail
  assert result.fn == cast[proc (param: pointer){.nimcall.}](0xCAFE)
  result = result.prev
  result.next = nil
  dq.tail.prev = result.prev
  result.prev = nil
  if dq.tail.prev.isNil:
    # Stealing the last task in the deque
    assert dq.head == result
    dq.head = dq.tail
  else:
    dq.tail.prev.next = dq.tail

  dec dq.num_tasks
  inc dq.num_steals

template deque_list_tl_multisteal_impl(
        result: var Task,
        dq: DequeListTl,
        stolen: var int32,
        maxClamp: untyped,
        tailAssign: untyped
      ): untyped =

  assert not dq.isNil

  if dq.deque_list_tl_empty():
    return nil

  # Make sure to steal at least one task
  var n{.inject.} = dq.num_tasks div 2
  if n == 0: n = 1
  maxClamp # <-- 1st statement injected here

  result = dq.tail
  tailAssign # <-- 2nd statement injected here
  assert result.fn == cast[proc (param: pointer){.nimcall.}](0xCAFE)

  # Walk backwards
  for i in 0 ..< n:
    result = result.prev

  dq.tail.prev.next = nil
  dq.tail.prev = result.prev
  result.prev = nil
  if dq.tail.prev.isNil:
    # tealing the last task of the deque
    assert dq.head == result
    dq.head = dq.tail
  else:
    dq.tail.prev.next = dq.tail

  dq.num_tasks -= n
  inc dq.num_steals
  stolen = n

func deque_list_tl_steal_many(
       dq: DequeListTl,
       tail: var Task,
       max: int32,
       stolen: var int32
     ): Task =
  # Steal up to half of the deque's tasks, but at most max tasks
  # tail will point to the last task in the returned list (head is returned)
  # stolen will contain the number of transferred tasks

  deque_list_tl_multisteal_impl(
        result, dq, stolen):
    if n > max: n = max
  do:
    tail = result.prev

func deque_list_tl_steal_many(
       dq: DequeListTl,
       max: int32,
       stolen: var int32
     ): Task =
  # Steal up to half of the deque's tasks, but at most max tasks
  # stolen will contain the number of transferred tasks

  deque_list_tl_multisteal_impl(
        result, dq, stolen):
    if n > max: n = max
  do:
    discard

func deque_list_tl_steal_half(
       dq: DequeListTl,
       tail: var Task,
       stolen: var int32
      ): Task =
  # Steal half of the deque's task
  # tail will point to the last task in the returned list (head is returned)
  # stolen will contain the number of transferred tasks

  deque_list_tl_multisteal_impl(
        result, dq, stolen):
    discard
  do:
    tail = result.prev

func deque_list_tl_steal_half(
       dq: DequeListTl,
       stolen: var int32
      ): Task =
  # Steal half of the deque's task
  # tail will point to the last task in the returned list (head is returned)
  # stolen will contain the number of transferred tasks

  deque_list_tl_multisteal_impl(
        result, dq, stolen):
    discard
  do:
    discard

# Unit tests
# ---------------------------------------------------------------

when isMainModule:
  import unittest

  const
    N = 1000000 # Number of tasks to push/pop/steal
    M = 100     # Max number of tasks to steal in one swoop

  type
    Data = object
      a, b: int32

  suite "Testing DequeListTl":
    var deq: DequeListTl

    test "Instantiation":
      deq = deque_list_tl_new()

      check:
        deq.deque_list_tl_empty()
        deq.deque_list_tl_num_tasks() == 0

    test "Pushing data":
      for i in 0'i32 ..< N:
        let t = deq.deque_list_tl_task_new()
        check: not t.isNil
        let d = cast[ptr Data](task_data(t))
        d[] = Data(a: i, b: i+1)
        deque_list_tl_push(deq, t)
