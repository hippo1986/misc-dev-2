from sets import *

from threading import *

# this computes the list of sets of elements that needs to be recomputed
def compute_recompute(key, _deps):
  # the result will be a list of sets
  res = []
  # current_sets of recomputation
  current_set = _deps[key]
  # while there is dependencies
  while len(current_set) > 0:
    # we initialize the next set
    next_set = Set()
    # adding all following dependencies
    for i in current_set:
      next_set.update(_deps[i])
    # we save the current_set by appending it in the res
    res.append(current_set)
    # and the current_set is the next one
    current_set = next_set

  # here we are sure that current_set = Set(), and that we are done

  # reverse traversing the list of sets, with i
  resi = range(0, len(res))
  resi.reverse()
  for i in resi:
    # we remove all the elements from the current set from the others
    for j in range(0, i):
      res[j] -= res[i]

  # finally we return res
  return res

class SpreadSheet:

  # contains 
  # (formula::String, value::Object,)
  # if fromula is None then it's direclt a value
  _cells = {}

  # dep: downside dependency
  # a dict of key::String to set of keys
  # k -> {k1, k2, k3} means that the value of k is used in the computation of k1, k2, k3
  _dep = {}

  # stack of currently evaluating cells
  _dep_stack = []

  def __init__(self, _globals = None):
    if _globals == None:
      self._globals = globals()
    else:
      self._globals = _globals

    self._debug = False

    self.glock = Lock()

    pass


  def __str__(self):
    res = ""

    for i in self._cells:      
      res += i 
      formula = self.getformula(i)
      if formula <> None:
        res += " ::= " + formula[1:]

      res += " = " + str(self[i]) + "\n"

    res += str(self._dep) + "\n"

    return res

  # this is a frontend version for __setitem__
  # this one is locked. All thread changing a cell value should use this function
  # block = False means that if the lock is taken we are getting out directly
  def setformula(self, key, formula, blocking = True):
    
    if not blocking and self.glock.locked():
      return None    
    
    self.glock.acquire()
    self[key] = formula
    self.glock.release()    
    return self[key]

  # we are setting a value
  def __setitem__(self, key, formula):

    if self._debug:
      print "self.__setitem__(" + key + ", " + str(formula) + ")"

    # first, as we change the formula of the cell
    # we remove its dependency to other cell
    for i in self._dep:
      self._dep[i].discard(key)    

    # if I am not registered in _dep I do so
    if key not in self._dep:
      self._dep[key] = Set()

    # then we push the key in the dependency stack
    self._dep_stack.append(key)

    # here we change the formula of the cell
    # and thus recompute it
    if isinstance(formula, str) and formula[0] == '=':
      try:
        self._cells[key] = (formula[1:], eval(formula[1:], self._globals, self))
      except Exception as e:
        self._cells[key] = (formula[1:], str(e))
    else:
      self._cells[key] = (None, formula)

    # we pop the key in the dependency stack
    self._dep_stack.pop()

    # than we recompute all dependencies
    # TODO: compute better dependencies to avoid recompute several time the same var
    # DONE

    recomputesets = compute_recompute(key, self._dep)

    # we "neutralize" the dependency stack
    l = self._dep_stack
    self._dep_stack = []
    
    if self._debug:
      print "recomputesets := " + str(recomputesets)

    # recompute all dependencies
    for i in recomputesets:
        for j in i:
          if self._debug:
            print "recomputing " + j

          # grab the formula, and if it exist then recompute cell value
          f = self.getformula(key)
          if f != None:
            try:
              self._cells[key] = (f[1:], eval(f[1:], self._globals, self))
            except Exception as e:
              self._cells[key] = (f[1:], str(e))

    # restore the dependency stack
    self._dep_stack = l

  def getformula(self, key):
    # we get the entry for the key
    c = self._cells[key]
    # and just return the first projection
    if c[0] == None:
      return None
    else:
      return "=" + c[0]

  def __getitem__(self, key):
    # we get the entry for the key
    c = self._cells[key]

    # look if the evaluation comes from another cell computation
    if len(self._dep_stack) > 0:
      # yes, so we are a dependency to another cell
      self._dep[key].add(self._dep_stack[len(self._dep_stack)-1])

    # and just return the second projection
    return c[1]
