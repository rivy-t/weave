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

# Work-stealing and scheduling routines
# ---------------------------------------------------------------

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