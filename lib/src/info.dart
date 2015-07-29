// Copyright (c) 2015, the Dart project authors.  Please see the AUTHORS file
// for details. All rights reserved. Use of this source code is governed by a
// BSD-style license that can be found in the LICENSE file.

/// Defines static information collected by the type checker and used later by
/// emitters to generate code.
library dev_compiler.src.info;

import 'package:analyzer/src/generated/ast.dart';
import 'package:analyzer/src/generated/element.dart';
import 'package:analyzer/src/generated/error.dart';
import 'package:analyzer/src/generated/parser.dart';

import 'package:dev_compiler/src/checker/rules.dart';
import 'package:dev_compiler/src/utils.dart' as utils;

/// Represents a summary of the results collected by running the program
/// checker.
class CheckerResults {
  final List<LibraryInfo> libraries;
  final TypeRules rules;
  final bool failure;

  CheckerResults(this.libraries, this.rules, this.failure);
}

/// Computed information about each library.
class LibraryInfo {
  /// Canonical name of the library. This is unfortunately not derived from the
  /// library directive as it doesn't have any meaningful rules enforced.
  /// Instead, this is inferred from the path to the file defining the library.
  final String name;

  /// Corresponding analyzer element.
  final LibraryElement library;

  LibraryInfo(library)
      : library = library,
        name = utils.canonicalLibraryName(library);
}

class LibraryUnit {
  final CompilationUnit library;
  final List<CompilationUnit> parts;

  LibraryUnit(this.library, this.parts);

  Iterable<CompilationUnit> get libraryThenParts sync* {
    yield library;
    yield* parts;
  }

  Iterable<CompilationUnit> get partsThenLibrary sync* {
    yield* parts;
    yield library;
  }

  /// Creates a clone of this library's AST.
  LibraryUnit clone() {
    return new LibraryUnit(
        _cloneUnit(library), parts.map(_cloneUnit).toList(growable: false));
  }

  static CompilationUnit _cloneUnit(CompilationUnit oldNode) {
    var newNode = oldNode.accept(new _AstCloner());
    ResolutionCopier.copyResolutionData(oldNode, newNode);
    return newNode;
  }
}

class _AstCloner extends AstCloner {
  void _cloneProperties(AstNode clone, AstNode node) {
    if (clone != null) {
      CoercionInfo.set(clone, CoercionInfo.get(node));
      DynamicInvoke.set(clone, DynamicInvoke.get(node));
    }
  }

  @override
  AstNode cloneNode(AstNode node) {
    var clone = super.cloneNode(node);
    _cloneProperties(clone, node);
    return clone;
  }

  @override
  List cloneNodeList(List list) {
    var clone = super.cloneNodeList(list);
    for (int i = 0, len = list.length; i < len; i++) {
      _cloneProperties(clone[i], list[i]);
    }
    return clone;
  }

  // TODO(jmesserly): as a workaround for analyzer <0.26.0-alpha.1.
  // ResolutionCopier won't copy the type, so we do it here.
  @override
  AwaitExpression visitAwaitExpression(AwaitExpression node) {
    var clone = super.visitAwaitExpression(node);
    clone.staticType = node.staticType;
    clone.propagatedType = node.propagatedType;
    return clone;
  }
}

// The abstract type of coercions mapping one type to another.
// This class also exposes static builder functions which
// check for errors and reduce redundant coercions to the identity.
abstract class Coercion {
  final DartType fromType;
  final DartType toType;
  Coercion(this.fromType, this.toType);
  static Coercion cast(DartType fromT, DartType toT) => new Cast(fromT, toT);
  static Coercion identity(DartType type) => new Identity(type);
  static Coercion error() => new CoercionError();
}

// Coercion which casts one type to another
class Cast extends Coercion {
  Cast(DartType fromType, DartType toType) : super(fromType, toType);
}

// The identity coercion
class Identity extends Coercion {
  Identity(DartType fromType) : super(fromType, fromType);
}

// The error coercion.  This coercion signals that a coercion
// could not be generated.  The code generator should not see
// these.
class CoercionError extends Coercion {
  CoercionError() : super(null, null);
}

// TODO(jmesserly): this could use some refactoring. These are essentially
// like ErrorCodes in analyzer, but we're including some details in our message.
// Analyzer instead has template strings, and replaces '{0}' with the first
// argument.
abstract class StaticInfo {
  /// AST Node this info is attached to.
  AstNode get node;

  // TODO(jmesserly): review the usage of error codes. We probably want our own,
  // as well as some DDC specific [ErrorType]s.
  ErrorCode toErrorCode();

  // TODO(jmesserly): what convention to use here?
  String get name => 'dev_compiler.$runtimeType';

  List<Object> get arguments => [node];

  AnalysisError toAnalysisError() {
    int begin = node is AnnotatedNode
        ? (node as AnnotatedNode).firstTokenAfterCommentAndMetadata.offset
        : node.offset;
    int length = node.end - begin;
    var source = (node.root as CompilationUnit).element.source;
    return new AnalysisError(source, begin, length, toErrorCode(), arguments);
  }
}

/// Implicitly injected expression conversion.
abstract class CoercionInfo extends StaticInfo {
  final TypeRules rules;

  final Expression node;

  DartType get convertedType;

  CoercionInfo(this.rules, this.node);

  DartType get baseType => rules.getStaticType(node);
  DartType get staticType => convertedType;

  String get message;
  toErrorCode() => new HintCode(name, message);

  static const String _propertyName = 'dev_compiler.src.info.CoercionInfo';

  /// Gets the coercion info associated with this node.
  static CoercionInfo get(AstNode node) => node.getProperty(_propertyName);

  /// Sets the coercion info associated with this node.
  static CoercionInfo set(AstNode node, CoercionInfo info) {
    node.setProperty(_propertyName, info);
    return info;
  }
}

// Base class for all casts from base type to sub type.
abstract class DownCast extends CoercionInfo {
  Cast _cast;

  DownCast._internal(TypeRules rules, Expression expression, this._cast)
      : super(rules, expression) {
    assert(_cast.toType != baseType &&
        _cast.fromType == baseType &&
        (baseType.isDynamic ||
            // Call methods make the following non-redundant
            _cast.toType.isSubtypeOf(baseType) ||
            baseType.isAssignableTo(_cast.toType)));
  }

  Cast get cast => _cast;

  DartType get convertedType => _cast.toType;

  @override List<Object> get arguments => [node, baseType, convertedType];
  @override String get message => '{0} ({1}) will need runtime check '
      'to cast to type {2}';

  // Factory to create correct DownCast variant.
  static StaticInfo create(TypeRules rules, Expression expression, Cast cast,
      {String reason}) {
    final fromT = cast.fromType;
    final toT = cast.toType;

    // toT <:_R fromT => to <: fromT
    // NB: classes with call methods are subtypes of function
    // types, but the function type is not assignable to the class
    assert(toT.isSubtypeOf(fromT) || fromT.isAssignableTo(toT));

    // Handle null call specially.
    if (expression is NullLiteral) {
      if (rules.isNonNullableType(toT)) {
        reason = "null is invalid as a $toT";
        return new StaticTypeError(rules, expression, toT, reason: reason);
      } else {
        // We should only get here if some coercion is required.
        assert(rules.maybeNonNullableType(toT));
        // TODO(vsm): Create a NullCast for this once we revisit nonnullability.
        return new DownCastImplicit(rules, expression, cast);
      }
    }

    // Inference "casts":
    if (expression is Literal) {
      // fromT should be an exact type - this will almost certainly fail at
      // runtime.
      return new StaticTypeError(rules, expression, toT, reason: reason);
    }
    if (expression is FunctionExpression) {
      // fromT should be an exact type - this will almost certainly fail at
      // runtime.
      return new UninferredClosure(rules, expression, cast);
    }
    if (expression is InstanceCreationExpression) {
      // fromT should be an exact type - this will almost certainly fail at
      // runtime.
      return new StaticTypeError(rules, expression, toT, reason: reason);
    }

    // Composite cast: these are more likely to fail.
    if (!rules.isGroundType(toT)) {
      // This cast is (probably) due to our different treatment of dynamic.
      // It may be more likely to fail at runtime.
      return new DownCastComposite(rules, expression, cast);
    }

    // Dynamic cast
    if (fromT.isDynamic) {
      return new DynamicCast(rules, expression, cast);
    }

    // Assignment cast
    var parent = expression.parent;
    if (parent is VariableDeclaration && (parent.initializer == expression)) {
      return new AssignmentCast(rules, expression, cast);
    }

    // Other casts
    return new DownCastImplicit(rules, expression, cast);
  }
}

//
// Standard down casts.  These casts are implicitly injected by the compiler.
//

// A down cast from dynamic to T.
class DynamicCast extends DownCast {
  DynamicCast(TypeRules rules, Expression expression, Cast cast)
      : super._internal(rules, expression, cast);

  toErrorCode() => new HintCode(name, message);
}

// A down cast due to a variable declaration to a ground type.  E.g.,
//   T x = expr;
// where T is ground.  We exclude non-ground types as these behave differently
// compared to standard Dart.
class AssignmentCast extends DownCast {
  AssignmentCast(TypeRules rules, Expression expression, Cast cast)
      : super._internal(rules, expression, cast);

  toErrorCode() => new HintCode(name, message);
}

//
// Temporary "casts" of allocation sites - literals, constructor invocations,
// and closures.  These should be handled by contextual inference.  In most
// cases, inference will be sufficient, though in some it may unmask an actual
// error: e.g.,
//   List<int> l = [1, 2, 3]; // Inference succeeds
//   List<String> l = [1, 2, 3]; // Inference reveals static type error
// We're marking all as warnings for now.
//
// TODO(vsm,leafp): Remove this.
class UninferredClosure extends DownCast {
  UninferredClosure(TypeRules rules, FunctionExpression expression, Cast cast)
      : super._internal(rules, expression, cast);

  toErrorCode() => new StaticTypeWarningCode(name, message);
}

//
// Implicit down casts.  These are only injected by the compiler by flag.
//

// A down cast to a non-ground type.  These behave differently from standard
// Dart and may be more likely to fail at runtime.
class DownCastComposite extends DownCast {
  DownCastComposite(TypeRules rules, Expression expression, Cast cast)
      : super._internal(rules, expression, cast);

  toErrorCode() => new StaticTypeWarningCode(name, message);
}

// A down cast to a non-ground type.  These behave differently from standard
// Dart and may be more likely to fail at runtime.
class DownCastImplicit extends DownCast {
  DownCastImplicit(TypeRules rules, Expression expression, Cast cast)
      : super._internal(rules, expression, cast);

  toErrorCode() => new StaticTypeWarningCode(name, message);
}

// An inferred type for the wrapped expression, which may need to be
// reified into the term
abstract class InferredTypeBase extends CoercionInfo {
  final DartType _type;

  InferredTypeBase._internal(TypeRules rules, Expression expression, this._type)
      : super(rules, expression);

  DartType get type => _type;
  DartType get convertedType => type;
  @override String get message => '{0} has inferred type {1}';
  @override List get arguments => [node, type];

  toErrorCode() => new HintCode(name, message);
}

// Standard / unspecialized inferred type
class InferredType extends InferredTypeBase {
  InferredType(TypeRules rules, Expression expression, DartType type)
      : super._internal(rules, expression, type);

  // Factory to create correct InferredType variant.
  static InferredTypeBase create(
      TypeRules rules, Expression expression, DartType type) {
    // Specialized inference:
    if (expression is Literal) {
      return new InferredTypeLiteral(rules, expression, type);
    }
    if (expression is InstanceCreationExpression) {
      return new InferredTypeAllocation(rules, expression, type);
    }
    if (expression is FunctionExpression) {
      return new InferredTypeClosure(rules, expression, type);
    }
    return new InferredType(rules, expression, type);
  }
}

// An infered type for a literal expression.
class InferredTypeLiteral extends InferredTypeBase {
  InferredTypeLiteral(TypeRules rules, Expression expression, DartType type)
      : super._internal(rules, expression, type);
}

// An inferred type for a non-literal allocation site.
class InferredTypeAllocation extends InferredTypeBase {
  InferredTypeAllocation(TypeRules rules, Expression expression, DartType type)
      : super._internal(rules, expression, type);
}

// An inferred type for a closure expression
class InferredTypeClosure extends InferredTypeBase {
  InferredTypeClosure(TypeRules rules, Expression expression, DartType type)
      : super._internal(rules, expression, type);
}

class DynamicInvoke extends CoercionInfo {
  DynamicInvoke(TypeRules rules, Expression expression)
      : super(rules, expression);

  DartType get convertedType => rules.provider.dynamicType;
  String get message => '{0} requires dynamic invoke';
  toErrorCode() => new HintCode(name, message);

  static const String _propertyName = 'dev_compiler.src.info.DynamicInvoke';

  /// Whether this [node] is the target of a dynamic operation.
  static bool get(AstNode node) {
    var value = node.getProperty(_propertyName);
    return value != null ? value : false;
  }

  /// Sets whether this node is the target of a dynamic operation.
  static bool set(AstNode node, bool value) {
    // Free the storage for things that aren't dynamic.
    if (value == false) value = null;
    node.setProperty(_propertyName, value);
    return value;
  }
}

abstract class StaticError extends StaticInfo {
  final AstNode node;

  StaticError(this.node);

  String get message;

  toErrorCode() => new CompileTimeErrorCode(name, message);
}

class StaticTypeError extends StaticError {
  final DartType baseType;
  final DartType expectedType;
  String reason = null;

  StaticTypeError(TypeRules rules, Expression expression, this.expectedType,
      {this.reason})
      : baseType = rules.getStaticType(expression),
        super(expression);

  @override List<Object> get arguments => [node, baseType, expectedType];
  @override String get message =>
      'Type check failed: {0} ({1}) is not of type {2}' +
          ((reason == null) ? '' : ' because $reason');
}

class InvalidVariableDeclaration extends StaticError {
  final DartType expectedType;

  InvalidVariableDeclaration(
      TypeRules rules, AstNode declaration, this.expectedType)
      : super(declaration);

  @override List<Object> get arguments => [expectedType];
  @override String get message => 'Type check failed: null is not of type {0}';
}

class InvalidParameterDeclaration extends StaticError {
  final DartType expectedType;

  InvalidParameterDeclaration(
      TypeRules rules, FormalParameter declaration, this.expectedType)
      : super(declaration);

  @override List<Object> get arguments => [node, expectedType];
  @override String get message => 'Type check failed: {0} is not of type {1}';
}

class InvalidRuntimeCheckError extends StaticError {
  final DartType type;

  InvalidRuntimeCheckError(AstNode node, this.type) : super(node) {
    assert(node is IsExpression || node is AsExpression);
  }

  @override List<Object> get arguments => [type];
  String get message => "Invalid runtime check on non-ground type {0}";
}

// Invalid override of an instance member of a class.
abstract class InvalidOverride extends StaticError {
  /// Member declaration with the invalid override.
  final ExecutableElement element;

  /// Type (class or interface) that provides the base declaration.
  final InterfaceType base;

  /// Actual type of the overridden member.
  final DartType subType;

  /// Actual type of the base member.
  final DartType baseType;

  /// Whether the error comes from combining a base class and an interface
  final bool fromBaseClass;

  /// Whether the error comes from a mixin (either overriding a base class or an
  /// interface declaration).
  final bool fromMixin;

  InvalidOverride(
      AstNode node, this.element, this.base, this.subType, this.baseType)
      : fromBaseClass = node is ExtendsClause,
        fromMixin = node.parent is WithClause,
        super(node);

  ClassElement get parent => element.enclosingElement;

  @override List<Object> get arguments =>
      [parent.name, element.name, subType, base, baseType];

  String _messageHelper(String errorName) {
    var lcErrorName = errorName.toLowerCase();
    var intro = fromBaseClass
        ? 'Base class introduces an $lcErrorName'
        : (fromMixin ? 'Mixin introduces an $lcErrorName' : errorName);
    return '$intro. The type of {0}.{1} ({2}) is not a '
        'subtype of {3}.{1} ({4}).';
  }
}

// Invalid override due to incompatible type.  I.e., the overridden signature
// is not compatible with the original.
class InvalidMethodOverride extends InvalidOverride {
  InvalidMethodOverride(AstNode node, ExecutableElement element,
      InterfaceType base, FunctionType subType, FunctionType baseType)
      : super(node, element, base, subType, baseType);

  String get message => _messageHelper('Invalid override');
}

// TODO(sigmund): delete, if we fix this, this should be part of the type
// inference, not something we detect in the checker.
// TODO(sigmund): split and track field, getter, setter, method separately
class InferableOverride extends InvalidOverride {
  InferableOverride(AstNode node, ExecutableElement element, InterfaceType base,
      DartType subType, DartType baseType)
      : super(node, element, base, subType, baseType);

  toErrorCode() => new CompileTimeErrorCode(name, message);
  String get message => _messageHelper('Invalid but inferable override');
}

/// Used to mark unexpected situations in our compiler were we couldn't compute
/// the type of an expression.
// TODO(sigmund): This is normally a result of another error that is caught by
// the analyzer, so this should likely be removed in the future.
class MissingTypeError extends StaticInfo {
  final AstNode node;
  toErrorCode() => new StaticTypeWarningCode(name, message);

  MissingTypeError(this.node);

  @override List<Object> get arguments => [node, node.runtimeType];
  String get message => "type analysis didn't compute the type of: {0} {1}";
}

/// Dart constructors have one weird quirk, illustrated with this example:
///
///     class Base {
///       var x;
///       Base() : x = print('Base.1') {
///         print('Base.2');
///       }
///     }
///
///     class Derived extends Base {
///       var y, z;
///       Derived()
///           : y = print('Derived.1'),
///             super(),
///             z = print('Derived.2') {
///         print('Derived.3');
///       }
///     }
///
/// The order will be Derived.1, Base.1, Derived.2, Base.2, Derived.3; this
/// ordering preserves the invariant that code can't observe uninitialized
/// state, however it results in super constructor body not being run
/// immediately after super initializers. Normally this isn't observable, but it
/// could be if initializers have side effects.
///
/// Better to have `super` at the end, as required by the Dart style guide:
/// <http://goo.gl/q1T4BB>
///
/// For now this is the only pattern we support.
class InvalidSuperInvocation extends StaticError {
  InvalidSuperInvocation(SuperConstructorInvocation node) : super(node);

  @override String get message => "super call must be last in an initializer "
      "list (see http://goo.gl/q1T4BB): {0}";
}
