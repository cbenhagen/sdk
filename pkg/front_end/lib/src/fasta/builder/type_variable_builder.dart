// Copyright (c) 2016, the Dart project authors.  Please see the AUTHORS file
// for details. All rights reserved. Use of this source code is governed by a
// BSD-style license that can be found in the LICENSE file.

library fasta.type_variable_builder;

import 'builder.dart'
    show
        LibraryBuilder,
        NullabilityBuilder,
        TypeBuilder,
        TypeDeclarationBuilder;

import 'package:kernel/ast.dart'
    show DartType, Nullability, TypeParameter, TypeParameterType;

import '../fasta_codes.dart'
    show
        templateCycleInTypeVariables,
        templateInternalProblemUnfinishedTypeVariable,
        templateTypeArgumentsOnTypeVariable;

import '../kernel/kernel_builder.dart'
    show ClassBuilder, NamedTypeBuilder, LibraryBuilder, TypeBuilder;

import '../problems.dart' show unsupported;

import '../source/source_library_builder.dart' show SourceLibraryBuilder;

import 'declaration.dart';

class TypeVariableBuilder extends TypeDeclarationBuilder {
  TypeBuilder bound;

  TypeBuilder defaultType;

  final TypeParameter actualParameter;

  TypeVariableBuilder actualOrigin;

  final bool isExtensionTypeParameter;

  TypeVariableBuilder(
      String name, SourceLibraryBuilder compilationUnit, int charOffset,
      {this.bound, this.isExtensionTypeParameter: false})
      : actualParameter = new TypeParameter(name, null)
          ..fileOffset = charOffset,
        super(null, 0, name, compilationUnit, charOffset);

  TypeVariableBuilder.fromKernel(
      TypeParameter parameter, LibraryBuilder compilationUnit)
      : actualParameter = parameter,
        // TODO(johnniwinther): Do we need to support synthesized type
        //  parameters from kernel?
        this.isExtensionTypeParameter = false,
        super(null, 0, parameter.name, compilationUnit, parameter.fileOffset);

  bool get isTypeVariable => true;

  String get debugName => "TypeVariableBuilder";

  StringBuffer printOn(StringBuffer buffer) {
    buffer.write(name);
    if (bound != null) {
      buffer.write(" extends ");
      bound.printOn(buffer);
    }
    return buffer;
  }

  String toString() => "${printOn(new StringBuffer())}";

  TypeVariableBuilder get origin => actualOrigin ?? this;

  /// The [TypeParameter] built by this builder.
  TypeParameter get parameter => origin.actualParameter;

  // Deliberately unrelated return type to statically detect more accidental
  // uses until Builder.target is fully retired.
  UnrelatedTarget get target => unsupported(
      "TypeVariableBuilder.target is deprecated. "
      "Use TypeVariableBuilder.parameter instead.",
      charOffset,
      fileUri);

  int get variance => parameter.variance;

  void set variance(int value) {
    parameter.variance = value;
  }

  DartType buildType(LibraryBuilder library,
      NullabilityBuilder nullabilityBuilder, List<TypeBuilder> arguments) {
    if (arguments != null) {
      int charOffset = -1; // TODO(ahe): Provide these.
      Uri fileUri = null; // TODO(ahe): Provide these.
      library.addProblem(
          templateTypeArgumentsOnTypeVariable.withArguments(name),
          charOffset,
          name.length,
          fileUri);
    }
    // If the bound is not set yet, the actual value is not important yet as it
    // will be set later.
    Nullability nullabilityIfOmitted = parameter.bound != null &&
            library != null &&
            library.isNonNullableByDefault
        ? TypeParameterType.computeNullabilityFromBound(parameter)
        : Nullability.legacy;
    DartType type = buildTypesWithBuiltArguments(
        library,
        nullabilityBuilder.build(library, ifOmitted: nullabilityIfOmitted),
        null);
    if (parameter.bound == null) {
      if (library is SourceLibraryBuilder) {
        library.pendingNullabilities.add(type);
      } else {
        library.addProblem(
            templateInternalProblemUnfinishedTypeVariable.withArguments(
                name, library?.uri),
            parameter.fileOffset,
            name.length,
            fileUri);
      }
    }
    return type;
  }

  DartType buildTypesWithBuiltArguments(LibraryBuilder library,
      Nullability nullability, List<DartType> arguments) {
    // TODO(dmitryas): Use [nullability].
    if (arguments != null) {
      int charOffset = -1; // TODO(ahe): Provide these.
      Uri fileUri = null; // TODO(ahe): Provide these.
      library.addProblem(
          templateTypeArgumentsOnTypeVariable.withArguments(name),
          charOffset,
          name.length,
          fileUri);
    }
    return new TypeParameterType(parameter, null, nullability);
  }

  TypeBuilder asTypeBuilder() {
    return new NamedTypeBuilder(name, const NullabilityBuilder.omitted(), null)
      ..bind(this);
  }

  void finish(
      LibraryBuilder library, ClassBuilder object, TypeBuilder dynamicType) {
    if (isPatch) return;
    DartType objectType =
        object.buildType(library, library.nullableBuilder, null);
    parameter.bound ??= bound?.build(library) ?? objectType;
    // If defaultType is not set, initialize it to dynamic, unless the bound is
    // explicitly specified as Object, in which case defaultType should also be
    // Object. This makes sure instantiation of generic function types with an
    // explicit Object bound results in Object as the instantiated type.
    parameter.defaultType ??= defaultType?.build(library) ??
        (bound != null && parameter.bound == objectType
            ? objectType
            : dynamicType.build(library));
  }

  /// Assigns nullabilities to types in [pendingNullabilities].
  ///
  /// It's a helper function to assign the nullabilities to type-parameter types
  /// after the corresponding type parameters have their bounds set or changed.
  /// The function takes into account that some of the types in the input list
  /// may be bounds to some of the type parameters of other types from the input
  /// list.
  static void finishNullabilities(LibraryBuilder libraryBuilder,
      List<TypeParameterType> pendingNullabilities) {
    // The bounds of type parameters may be type-parameter types of other
    // parameters from the same declaration.  In this case we need to set the
    // nullability for them first.  To preserve the ordering, we implement a
    // depth-first search over the types.  We use the fact that a nullability
    // of a type parameter type can't ever be 'nullable' if computed from the
    // bound. It allows us to use 'nullable' nullability as the marker in the
    // DFS implementation.
    Nullability marker = Nullability.nullable;
    List<TypeParameterType> stack =
        new List<TypeParameterType>.filled(pendingNullabilities.length, null);
    int stackTop = 0;
    for (TypeParameterType type in pendingNullabilities) {
      type.typeParameterTypeNullability = null;
    }
    for (TypeParameterType type in pendingNullabilities) {
      if (type.typeParameterTypeNullability != null) {
        // Nullability for [type] was already computed on one of the branches
        // of the depth-first search.  Continue to the next one.
        continue;
      }
      if (type.parameter.bound is TypeParameterType) {
        TypeParameterType current = type;
        TypeParameterType next = current.parameter.bound;
        while (next != null && next.typeParameterTypeNullability == null) {
          stack[stackTop++] = current;
          current.typeParameterTypeNullability = marker;

          current = next;
          if (current.parameter.bound is TypeParameterType) {
            next = current.parameter.bound;
            if (next.typeParameterTypeNullability == marker) {
              next.typeParameterTypeNullability = Nullability.neither;
              libraryBuilder.addProblem(
                  templateCycleInTypeVariables.withArguments(
                      next.parameter.name, current.parameter.name),
                  next.parameter.fileOffset,
                  next.parameter.name.length,
                  next.parameter.location.file);
              next = null;
            }
          } else {
            next = null;
          }
        }
        current.typeParameterTypeNullability =
            TypeParameterType.computeNullabilityFromBound(current.parameter);
        while (stackTop != 0) {
          --stackTop;
          current = stack[stackTop];
          current.typeParameterTypeNullability =
              TypeParameterType.computeNullabilityFromBound(current.parameter);
        }
      } else {
        type.typeParameterTypeNullability =
            TypeParameterType.computeNullabilityFromBound(type.parameter);
      }
    }
  }

  void applyPatch(covariant TypeVariableBuilder patch) {
    patch.actualOrigin = this;
  }

  TypeVariableBuilder clone(List<TypeBuilder> newTypes) {
    // TODO(dmitryas): Figure out if using [charOffset] here is a good idea.
    // An alternative is to use the offset of the node the cloned type variable
    // is declared on.
    return new TypeVariableBuilder(name, parent, charOffset,
        bound: bound.clone(newTypes));
  }

  @override
  bool operator ==(Object other) {
    return other is TypeVariableBuilder && parameter == other.parameter;
  }

  @override
  int get hashCode => parameter.hashCode;

  static List<TypeParameter> typeParametersFromBuilders(
      List<TypeVariableBuilder> builders) {
    if (builders == null) return null;
    List<TypeParameter> result =
        new List<TypeParameter>.filled(builders.length, null, growable: true);
    for (int i = 0; i < builders.length; i++) {
      result[i] = builders[i].parameter;
    }
    return result;
  }
}
