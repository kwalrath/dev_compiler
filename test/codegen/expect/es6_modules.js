'use strict';
const exports = {};
import dart from "dart/_runtime";
import core from "dart/core";
let dartx = dart.dartx;
const Callback = dart.typedef('Callback', () => dart.functionType(dart.void, [], {i: core.int}));
class A extends core.Object {}
class _A extends core.Object {}
const B$ = dart.generic(function(T) {
  class B extends core.Object {}
  return B;
});
let B = B$();
const _B$ = dart.generic(function(T) {
  class _B extends core.Object {}
  return _B;
});
let _B = _B$();
function f() {
}
dart.fn(f);
function _f() {
}
dart.fn(_f);
const constant = "abc";
exports.lazy = "abc";
exports.mutable = "abc";
// Exports:
exports.Callback = Callback;
exports.A = A;
exports.B$ = B$;
exports.B = B;
exports.f = f;
exports.constant = constant;
export default exports;
