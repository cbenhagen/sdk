// Copyright (c) 2018, the Dart project authors.  Please see the AUTHORS file
// for details. All rights reserved. Use of this source code is governed by a
// BSD-style license that can be found in the LICENSE file.

import 'package:analyzer/dart/ast/ast.dart';
import 'package:analyzer/dart/element/element.dart';
import 'package:analyzer/dart/element/type.dart';
import 'package:analyzer/src/dart/analysis/dependency/node.dart';

/// Collector of information about external nodes referenced by a node.
///
/// The workflow for using it is that the library builder creates a new
/// instance, fills it with names of import prefixes using [addImportPrefix].
/// Then for each node defined in the library, [collect] is called with
/// corresponding AST nodes to record references to external names, and
/// construct the API or implementation [Dependencies].
class ReferenceCollector {
  /// Local scope inside the node, containing local names such as parameters,
  /// local variables, local functions, local type parameters, etc.
  final _LocalScopes _localScopes = _LocalScopes();

  /// The list of names that are referenced without any prefix, neither an
  /// import prefix, nor a target expression.
  _NameSet _unprefixedReferences = _NameSet();

  /// The list of names that are referenced using an import prefix.
  ///
  /// It is filled by [addImportPrefix] and shared across all nodes.
  List<_ReferencedImportPrefixedNames> _importPrefixedReferences = [];

  /// The set of referenced class members.
  _ClassMemberReferenceSet _memberReferences = new _ClassMemberReferenceSet();

  /// Record that the [name] is a name of an import prefix.
  ///
  /// So, when we see code like `prefix.foo` we know that `foo` should be
  /// resolved in the import scope that corresponds to `prefix` (unless the
  /// name `prefix` is shadowed by a local declaration).
  void addImportPrefix(String name) {
    assert(_localScopes.isEmpty);
    for (var import in _importPrefixedReferences) {
      if (import.prefix == name) {
        return;
      }
    }
    _importPrefixedReferences.add(_ReferencedImportPrefixedNames(name));
  }

  /// Construct and return a new [Dependencies] with the given [tokenSignature]
  /// and all recorded references to external nodes in the give AST nodes.
  Dependencies collect(List<int> tokenSignature,
      {Expression expression,
      FormalParameterList formalParameters,
      FunctionBody functionBody,
      TypeAnnotation returnType,
      TypeAnnotation type}) {
    _localScopes.enter();
    if (expression != null) {
      _visitExpression(expression);
    }
    if (formalParameters != null) {
      _visitFormalParameters(formalParameters);
    }
    if (functionBody != null) {
      _visitFunctionBody(functionBody);
    }
    if (returnType != null) {
      _visitTypeAnnotation(returnType);
    }
    if (type != null) {
      _visitTypeAnnotation(type);
    }
    _localScopes.exit();

    var unprefixedReferencedNames = _unprefixedReferences.toList();
    _unprefixedReferences = _NameSet();

    var numberOfPrefixes = _importPrefixedReferences.length;
    var importPrefixes = List<String>(numberOfPrefixes);
    var importPrefixedReferencedNames = List<List<String>>(numberOfPrefixes);
    for (var i = 0; i < numberOfPrefixes; i++) {
      var import = _importPrefixedReferences[i];
      importPrefixes[i] = import.prefix;
      importPrefixedReferencedNames[i] = import.names.toList();
      import.clear();
    }

    var classMemberReferences = _memberReferences.toList();
    _memberReferences = _ClassMemberReferenceSet();

    return Dependencies(
      tokenSignature,
      unprefixedReferencedNames,
      importPrefixes,
      importPrefixedReferencedNames,
      classMemberReferences,
    );
  }

  /// Return the collector for the import prefix with the given [name].
  _ReferencedImportPrefixedNames _importPrefix(String name) {
    assert(!_localScopes.contains(name));
    for (var i = 0; i < _importPrefixedReferences.length; i++) {
      var references = _importPrefixedReferences[i];
      if (references.prefix == name) {
        return references;
      }
    }
    return null;
  }

  void _recordClassMemberReference(
      DartType targetType, bool withSuper, String name) {
    if (targetType is InterfaceType) {
      _memberReferences.add(targetType, withSuper, name);
    }
  }

  /// Record a new unprefixed name reference.
  void _recordUnprefixedReference(String name) {
    assert(!_localScopes.contains(name));
    _unprefixedReferences.add(name);
  }

  void _visitExpression(Expression node) {
    if (node == null) return;

    if (node is AssignmentExpression) {
      _visitExpression(node.leftHandSide);
      _visitExpression(node.rightHandSide);
      // TODO(scheglov) operator
    } else if (node is BinaryExpression) {
      _visitExpression(node.leftOperand);
      _visitExpression(node.rightOperand);
      _recordClassMemberReference(
        node.leftOperand.staticType,
        false,
        node.operator.lexeme,
      );
    } else if (node is BooleanLiteral) {
      // no dependencies
    } else if (node is ConditionalExpression) {
      // TODO(scheglov) test
      _visitExpression(node.condition);
      _visitExpression(node.thenExpression);
      _visitExpression(node.elseExpression);
    } else if (node is DoubleLiteral) {
      // no dependencies
    } else if (node is IndexExpression) {
      _visitExpression(node.target);
      _visitExpression(node.index);
    } else if (node is IntegerLiteral) {
      // no dependencies
    } else if (node is ListLiteral) {
      _visitListLiteral(node);
    } else if (node is MapLiteral) {
      _visitMapLiteral(node);
    } else if (node is MethodInvocation) {
      _visitMethodInvocation(node);
    } else if (node is ParenthesizedExpression) {
      _visitExpression(node.expression);
    } else if (node is PrefixExpression) {
      _visitPrefixExpression(node);
    } else if (node is PrefixedIdentifier) {
      _visitPrefixedIdentifier(node);
    } else if (node is SetLiteral) {
      _visitSetLiteral(node);
    } else if (node is SimpleIdentifier) {
      _visitSimpleIdentifier(node);
    } else {
//      throw UnimplementedError('(${node.runtimeType}) $node');
    }
  }

  void _visitForEachStatement(ForEachStatement node) {
    var loopVariable = node.loopVariable;
    if (loopVariable != null) {
      _visitTypeAnnotation(loopVariable.type);
    }

    var loopIdentifier = node.identifier;
    if (loopIdentifier != null) {
      _visitExpression(loopIdentifier);
    }

    _visitExpression(node.iterable);

    _localScopes.enter();
    if (loopVariable != null) {
      _localScopes.add(loopVariable.identifier.name);
    }

    _visitStatement(node.body);

    _localScopes.exit();
  }

  void _visitFormalParameters(FormalParameterList node) {
    if (node == null) return;

    var parameters = node.parameters;
    for (var i = 0; i < parameters.length; i++) {
      FormalParameter parameter = parameters[i];
      if (parameter is DefaultFormalParameter) {
        DefaultFormalParameter defaultParameter = parameter;
        parameter = defaultParameter.parameter;
        _visitExpression(defaultParameter.defaultValue);
      }
      if (parameter.identifier != null) {
        _localScopes.add(parameter.identifier.name);
      }
      if (parameter is FunctionTypedFormalParameter) {
        _visitTypeAnnotation(parameter.returnType);
        _visitFormalParameters(parameter.parameters);
      } else if (parameter is SimpleFormalParameter) {
        _visitTypeAnnotation(parameter.type);
      } else {
        // TODO(scheglov) constructors and field formal parameters
//        throw StateError('Unexpected: (${parameter.runtimeType}) $parameter');
      }
    }
  }

  void _visitForStatement(ForStatement node) {
    _localScopes.enter();

    _visitVariableList(node.variables);
    _visitExpression(node.initialization);
    _visitExpression(node.condition);

    var updaters = node.updaters;
    for (var i = 0; i < updaters.length; i++) {
      _visitExpression(updaters[i]);
    }

    _visitStatement(node.body);

    _localScopes.exit();
  }

  void _visitFunctionBody(FunctionBody node) {
    if (node == null) {
      // nothing
    } else if (node is BlockFunctionBody) {
      _visitStatement(node.block);
    } else if (node is EmptyFunctionBody) {
      return;
    } else if (node is ExpressionFunctionBody) {
      _visitExpression(node.expression);
    } else {
      throw UnimplementedError('(${node.runtimeType}) $node');
    }
  }

  void _visitFunctionDeclarationStatement(FunctionDeclarationStatement node) {
    var function = node.functionDeclaration;
    _visitTypeAnnotation(function.returnType);

    _localScopes.enter();
    var functionExpression = function.functionExpression;
    _visitFormalParameters(functionExpression.parameters);
    _visitFunctionBody(functionExpression.body);
    _localScopes.exit();
  }

  void _visitListLiteral(ListLiteral node) {
    _visitTypeArguments(node.typeArguments);
    var elements = node.elements;
    for (var i = 0; i < elements.length; i++) {
      var element = elements[i];
      _visitExpression(element);
    }
  }

  void _visitMapLiteral(MapLiteral node) {
    _visitTypeArguments(node.typeArguments);
    var entries = node.entries;
    for (var i = 0; i < entries.length; i++) {
      var entry = entries[i];
      _visitExpression(entry.key);
      _visitExpression(entry.value);
    }
  }

  void _visitMethodInvocation(MethodInvocation node) {
    _visitExpression(node.target);
    var realTarget = node.realTarget;
    if (realTarget == null) {
      _visitExpression(node.methodName);
    } else if (realTarget is SuperExpression) {
      // TODO(scheglov) implement
      //        throw UnimplementedError('$node');
    } else {
      _recordClassMemberReference(
        realTarget.staticType,
        false,
        node.methodName.name,
      );
    }
    // TODO(scheglov) tests
    var arguments = node.argumentList.arguments;
    for (var i = 0; i < arguments.length; i++) {
      var argument = arguments[i];
      _visitExpression(argument);
    }
  }

  void _visitPrefixedIdentifier(PrefixedIdentifier node) {
    var prefix = node.prefix;
    var prefixElement = prefix.staticElement;
    if (prefixElement is PrefixElement) {
      var prefixName = prefix.name;
      // TODO(scheglov) remove this null check work around
      var importPrefix = _importPrefix(prefixName);
      if (importPrefix != null) {
        importPrefix.add(node.identifier.name);
      }
    } else {
      _visitExpression(prefix);
      _recordClassMemberReference(
        prefix.staticType,
        false,
        node.identifier.name,
      );
    }
  }

  void _visitPrefixExpression(PrefixExpression node) {
    _visitExpression(node.operand);

    var operatorName = node.operator.lexeme;
    if (operatorName == '-') operatorName = 'unary-';

    _recordClassMemberReference(
      node.operand.staticType,
      false,
      operatorName,
    );
  }

  void _visitSetLiteral(SetLiteral node) {
    _visitTypeArguments(node.typeArguments);
    var elements = node.elements;
    for (var i = 0; i < elements.length; i++) {
      var element = elements[i];
      _visitExpression(element);
    }
  }

  void _visitSimpleIdentifier(SimpleIdentifier node) {
    if (node.isSynthetic) return;

    var name = node.name;
    if (!_localScopes.contains(name) && name != 'void' && name != 'dynamic') {
      _recordUnprefixedReference(name);
    }
  }

  void _visitStatement(Statement node) {
    if (node == null) {
      // nothing
    } else if (node is AssertStatement) {
      _visitExpression(node.condition);
      _visitExpression(node.message);
    } else if (node is Block) {
      _visitStatements(node.statements);
    } else if (node is BreakStatement) {
      // nothing
    } else if (node is ContinueStatement) {
      // nothing
    } else if (node is DoStatement) {
      _visitStatement(node.body);
      _visitExpression(node.condition);
    } else if (node is EmptyStatement) {
      // nothing
    } else if (node is ExpressionStatement) {
      _visitExpression(node.expression);
    } else if (node is ForEachStatement) {
      _visitForEachStatement(node);
    } else if (node is ForStatement) {
      _visitForStatement(node);
    } else if (node is FunctionDeclarationStatement) {
      _visitFunctionDeclarationStatement(node);
    } else if (node is IfStatement) {
      _visitExpression(node.condition);
      _visitStatement(node.thenStatement);
      _visitStatement(node.elseStatement);
    } else if (node is LabeledStatement) {
      _visitStatement(node.statement);
    } else if (node is ReturnStatement) {
      _visitExpression(node.expression);
    } else if (node is SwitchStatement) {
      _visitSwitchStatement(node);
    } else if (node is TryStatement) {
      _visitTryStatement(node);
    } else if (node is VariableDeclarationStatement) {
      _visitVariableList(node.variables);
    } else if (node is WhileStatement) {
      _visitExpression(node.condition);
      _visitStatement(node.body);
    } else if (node is YieldStatement) {
      _visitExpression(node.expression);
    } else {
      throw UnimplementedError('(${node.runtimeType}) $node');
    }
  }

  void _visitStatements(List<Statement> statements) {
    _localScopes.enter();

    for (var i = 0; i < statements.length; i++) {
      var statement = statements[i];
      if (statement is FunctionDeclarationStatement) {
        _localScopes.add(statement.functionDeclaration.name.name);
      } else if (statement is VariableDeclarationStatement) {
        var variables = statement.variables.variables;
        for (int i = 0; i < variables.length; i++) {
          _localScopes.add(variables[i].name.name);
        }
      }
    }

    for (var i = 0; i < statements.length; i++) {
      var statement = statements[i];
      _visitStatement(statement);
    }

    _localScopes.exit();
  }

  void _visitSwitchStatement(SwitchStatement node) {
    _visitExpression(node.expression);
    var members = node.members;
    for (var i = 0; i < members.length; i++) {
      var member = members[i];
      if (member is SwitchCase) {
        _visitExpression(member.expression);
      }
      _visitStatements(member.statements);
    }
  }

  void _visitTryStatement(TryStatement node) {
    _visitStatement(node.body);
    // TODO(scheglov) catch
    _visitStatement(node.finallyBlock);
  }

  void _visitTypeAnnotation(TypeAnnotation node) {
    if (node == null) return;

    if (node is GenericFunctionType) {
      _localScopes.enter();

      if (node.typeParameters != null) {
        var typeParameters = node.typeParameters.typeParameters;
        for (var i = 0; i < typeParameters.length; i++) {
          var typeParameter = typeParameters[i];
          _localScopes.add(typeParameter.name.name);
        }
        for (var i = 0; i < typeParameters.length; i++) {
          var typeParameter = typeParameters[i];
          _visitTypeAnnotation(typeParameter.bound);
        }
      }

      _visitTypeAnnotation(node.returnType);
      _visitFormalParameters(node.parameters);

      _localScopes.exit();
    } else if (node is TypeName) {
      var identifier = node.name;
      _visitExpression(identifier);
      _visitTypeArguments(node.typeArguments);
    } else {
      throw UnimplementedError('(${node.runtimeType}) $node');
    }
  }

  void _visitTypeArguments(TypeArgumentList typeArguments) {
    if (typeArguments != null) {
      var arguments = typeArguments.arguments;
      for (var i = 0; i < arguments.length; i++) {
        var argument = arguments[i];
        _visitTypeAnnotation(argument);
      }
    }
  }

  void _visitVariableList(VariableDeclarationList node) {
    if (node == null) return;

    _visitTypeAnnotation(node.type);

    var variables = node.variables;
    for (int i = 0; i < variables.length; i++) {
      var variable = variables[i];
      _localScopes.add(variable.name.name);
      _visitExpression(variable.initializer);
    }
  }
}

/// The sorted set of [ClassMemberReference]s.
class _ClassMemberReferenceSet {
  final List<ClassMemberReference> references = [];

  void add(InterfaceType type, bool withSuper, String name) {
    var class_ = type.element;
    var target = LibraryQualifiedName(class_.library.source.uri, class_.name);
    var reference = ClassMemberReference(target, withSuper, name);
    if (!references.contains(reference)) {
      references.add(reference);
    }
  }

  /// Return the sorted list of unique class member references.
  List<ClassMemberReference> toList() {
    references.sort(ClassMemberReference.compare);
    return references;
  }
}

/// The stack of names that are defined in a local scope inside the node,
/// such as parameters, local variables, local functions, local type
/// parameters, etc.
class _LocalScopes {
  /// The stack of name sets.
  final List<_NameSet> scopes = [];

  bool get isEmpty => scopes.isEmpty;

  /// Add the given [name] to the current local scope.
  void add(String name) {
    scopes.last.add(name);
  }

  /// Return whether the given [name] is defined in one of the local scopes.
  bool contains(String name) {
    for (var i = 0; i < scopes.length; i++) {
      if (scopes[i].contains(name)) {
        return true;
      }
    }
    return false;
  }

  /// Enter a new local scope, e.g. a block, or a type parameter scope.
  void enter() {
    scopes.add(_NameSet());
  }

  /// Exit the current local scope.
  void exit() {
    scopes.removeLast();
  }
}

class _NameSet {
  final List<String> names = [];

  void add(String name) {
    // TODO(scheglov) consider just adding, but toList() sort and unique
    if (!contains(name)) {
      names.add(name);
    }
  }

  bool contains(String name) => names.contains(name);

  List<String> toList() {
    names.sort(_compareStrings);
    return names;
  }

  static int _compareStrings(String first, String second) {
    return first.compareTo(second);
  }
}

class _ReferencedImportPrefixedNames {
  final String prefix;
  _NameSet names = _NameSet();

  _ReferencedImportPrefixedNames(this.prefix);

  void add(String name) {
    names.add(name);
  }

  void clear() {
    names = _NameSet();
  }
}