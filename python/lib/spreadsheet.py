from sets import *

# for a (god known) reason, the functions/module to be used in cells need to be import from here 
from math import sin, pi
import matplotlib.pyplot as plt


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

  def __str__(self):
    return str(self._cells) + "\n" + str(self._dep)

  # we are setting a value
  def __setitem__(self, key, formula):

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
        self._cells[key] = (formula[1:], eval(formula[1:], globals(), self))
      except Exception as e:
        self._cells[key] = (formula[1:], str(e))
    else:
      self._cells[key] = (None, formula)


    # we pop the key in the dependency stack
    self._dep_stack.pop()

    # than we recompute all dependencies
    try:
      for i in self._dep[key]:
        self.recompute(i)
    except:
      pass


  def getformula(self, key):
    # we get the entry for the key
    c = self._cells[key]
    # and just return the first projection
    if c[0] == None:
      return None
    else:
      return "=" + c[0]

  def recompute(self, key):
    # we set again the formula
    f = self.getformula(key)
    if f != None:

      # we "neutralize" the dependency stack
      l = self._dep_stack
      self._dep_stack = []
      # reset our formula
      self.__setitem__(key, f)

      # restore the dependency stack
      self._dep_stack = l

  def __getitem__(self, key):
    # we get the entry for the key
    c = self._cells[key]

    # look if the evaluation comes from another cell computation
    if len(self._dep_stack) > 0:
      # yes, so we are a dependency to another cell
      self._dep[key].add(self._dep_stack[len(self._dep_stack)-1])

    # and just return the second projection
    return c[1]