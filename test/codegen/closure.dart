library test;
import 'dart:js';

typedef void Callback({int i});

class Foo<T> {
  final int i;
  bool b;
  String s;
  T v;

  Foo(this.i, this.v);

  factory Foo.build() => new Foo(1, null);

  untyped_method(a, b) {}

  T pass(T t) => t;

  String typed_method(
      Foo foo, List list,
      int i, num n, double d, bool b, String s,
      JsArray a, JsObject o, JsFunction f) {
    return '';
  }

  optional_params(a, [b, c]) {}

  static named_params(a, {b, c}) {}

  // Avoid colliding with Function.name & Function.length, as Closure fails to
  // lower these to ES6 (https://github.com/google/closure-compiler/issues/1460)
  static name() => 'Foo.name()';
  static length() => 'Foo.length()';

  nullary_method() {}

  function_params(int f(x, [y]), g(x, {String y, z}), Callback cb) {
    cb(i: i);
  }

  String get prop => null;
  set prop(String value) {}

  static String get staticProp => null;
  static set staticProp(String value) {}

  static const String some_static_constant = "abc";
  static final String some_static_final = "abc";
  static String some_static_var = "abc";
}

class Bar {}

class Baz extends Foo<int> with Bar {
  Baz(int i) : super(i, 123);
}

void main(args) {
  print(Foo.name());
  print(Foo.length());
}

const String some_top_level_constant = "abc";
final String some_top_level_final = "abc";
String some_top_level_var = "abc";
