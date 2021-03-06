// Copyright (c) 2016, the Dart project authors.  Please see the AUTHORS file
// for details. All rights reserved. Use of this source code is governed by a
// BSD-style license that can be found in the LICENSE file.

library fasta.kernel_class_builder;

import 'package:kernel/ast.dart'
    show
        Class,
        Constructor,
        ThisExpression,
        DartType,
        DynamicType,
        Expression,
        Field,
        FunctionNode,
        InterfaceType,
        AsExpression,
        ListLiteral,
        Member,
        Name,
        Procedure,
        ReturnStatement,
        VoidType,
        MethodInvocation,
        ProcedureKind,
        StaticGet,
        Supertype,
        TypeParameter,
        TypeParameterType,
        Arguments,
        VariableDeclaration;

import 'package:kernel/ast.dart'
    show FunctionType, NamedType, TypeParameterType;

import 'package:kernel/class_hierarchy.dart' show ClassHierarchy;

import 'package:kernel/clone.dart' show CloneWithoutBody;

import 'package:kernel/core_types.dart' show CoreTypes;

import 'package:kernel/type_algebra.dart' show Substitution, getSubstitutionMap;

import 'package:kernel/type_environment.dart' show TypeEnvironment;

import '../dill/dill_member_builder.dart' show DillMemberBuilder;

import '../fasta_codes.dart'
    show
        LocatedMessage,
        Message,
        messageImplementsFutureOr,
        messagePatchClassOrigin,
        messagePatchClassTypeVariablesMismatch,
        messagePatchDeclarationMismatch,
        messagePatchDeclarationOrigin,
        noLength,
        templateFactoryRedirecteeHasTooFewPositionalParameters,
        templateFactoryRedirecteeInvalidReturnType,
        templateImplementsRepeated,
        templateImplementsSuperClass,
        templateMissingImplementationCause,
        templateMissingImplementationNotAbstract,
        templateOverriddenMethodCause,
        templateOverrideFewerNamedArguments,
        templateOverrideFewerPositionalArguments,
        templateOverrideMismatchNamedParameter,
        templateOverrideMoreRequiredArguments,
        templateOverrideTypeMismatchParameter,
        templateOverrideTypeMismatchReturnType,
        templateOverrideTypeVariablesMismatch,
        templateRedirectingFactoryIncompatibleBounds,
        templateRedirectingFactoryInvalidNamedParameterType,
        templateRedirectingFactoryInvalidPositionalParameterType,
        templateRedirectingFactoryMissingNamedParameter,
        templateRedirectingFactoryProvidesTooFewRequiredParameters,
        templateRedirectionTargetNotFound,
        templateTypeArgumentMismatch;

import '../names.dart' show noSuchMethodName;

import '../problems.dart' show unexpected, unhandled, unimplemented;

import '../type_inference/type_schema.dart' show UnknownType;

import 'kernel_builder.dart'
    show
        ClassBuilder,
        ConstructorReferenceBuilder,
        Declaration,
        KernelLibraryBuilder,
        KernelFunctionBuilder,
        KernelProcedureBuilder,
        KernelRedirectingFactoryBuilder,
        KernelNamedTypeBuilder,
        KernelTypeBuilder,
        KernelTypeVariableBuilder,
        LibraryBuilder,
        MemberBuilder,
        MetadataBuilder,
        ProcedureBuilder,
        Scope,
        TypeVariableBuilder;

import 'redirecting_factory_body.dart' show RedirectingFactoryBody;

import 'kernel_target.dart' show KernelTarget;

abstract class KernelClassBuilder
    extends ClassBuilder<KernelTypeBuilder, InterfaceType> {
  KernelClassBuilder actualOrigin;

  KernelClassBuilder(
      List<MetadataBuilder> metadata,
      int modifiers,
      String name,
      List<TypeVariableBuilder> typeVariables,
      KernelTypeBuilder supertype,
      List<KernelTypeBuilder> interfaces,
      Scope scope,
      Scope constructors,
      LibraryBuilder parent,
      int charOffset)
      : super(metadata, modifiers, name, typeVariables, supertype, interfaces,
            scope, constructors, parent, charOffset);

  Class get cls;

  Class get target => cls;

  Class get actualCls;

  @override
  KernelClassBuilder get origin => actualOrigin ?? this;

  /// [arguments] have already been built.
  InterfaceType buildTypesWithBuiltArguments(
      LibraryBuilder library, List<DartType> arguments) {
    assert(arguments == null || cls.typeParameters.length == arguments.length);
    return arguments == null ? cls.rawType : new InterfaceType(cls, arguments);
  }

  @override
  int get typeVariablesCount => typeVariables?.length ?? 0;

  List<DartType> buildTypeArguments(
      LibraryBuilder library, List<KernelTypeBuilder> arguments) {
    if (arguments == null && typeVariables == null) {
      return <DartType>[];
    }

    if (arguments == null && typeVariables != null) {
      List<DartType> result =
          new List<DartType>.filled(typeVariables.length, null, growable: true);
      for (int i = 0; i < result.length; ++i) {
        result[i] = typeVariables[i].defaultType.build(library);
      }
      return result;
    }

    if (arguments != null && arguments.length != (typeVariables?.length ?? 0)) {
      // That should be caught and reported as a compile-time error earlier.
      return unhandled(
          templateTypeArgumentMismatch
              .withArguments(typeVariables.length)
              .message,
          "buildTypeArguments",
          -1,
          null);
    }

    // arguments.length == typeVariables.length
    List<DartType> result =
        new List<DartType>.filled(arguments.length, null, growable: true);
    for (int i = 0; i < result.length; ++i) {
      result[i] = arguments[i].build(library);
    }
    return result;
  }

  /// If [arguments] are null, the default types for the variables are used.
  InterfaceType buildType(
      LibraryBuilder library, List<KernelTypeBuilder> arguments) {
    return buildTypesWithBuiltArguments(
        library, buildTypeArguments(library, arguments));
  }

  Supertype buildSupertype(
      LibraryBuilder library, List<KernelTypeBuilder> arguments) {
    Class cls = isPatch ? origin.target : this.cls;
    return new Supertype(cls, buildTypeArguments(library, arguments));
  }

  Supertype buildMixedInType(
      LibraryBuilder library, List<KernelTypeBuilder> arguments) {
    Class cls = isPatch ? origin.target : this.cls;
    if (arguments != null) {
      return new Supertype(cls, buildTypeArguments(library, arguments));
    } else {
      return new Supertype(
          cls,
          new List<DartType>.filled(
              cls.typeParameters.length, const UnknownType(),
              growable: true));
    }
  }

  void checkSupertypes(CoreTypes coreTypes) {
    // This method determines whether the class (that's being built) its super
    // class appears both in 'extends' and 'implements' clauses and whether any
    // interface appears multiple times in the 'implements' clause.
    if (interfaces == null) return;

    // Extract super class (if it exists).
    ClassBuilder superClass;
    KernelTypeBuilder superClassType = supertype;
    if (superClassType is KernelNamedTypeBuilder) {
      Declaration decl = superClassType.declaration;
      if (decl is ClassBuilder) {
        superClass = decl;
      }
    }

    // Validate interfaces.
    Map<ClassBuilder, int> problems;
    Map<ClassBuilder, int> problemsOffsets;
    Set<ClassBuilder> implemented = new Set<ClassBuilder>();
    for (KernelTypeBuilder type in interfaces) {
      if (type is KernelNamedTypeBuilder) {
        int charOffset = -1; // TODO(ahe): Get offset from type.
        Declaration decl = type.declaration;
        if (decl is ClassBuilder) {
          ClassBuilder interface = decl;
          if (superClass == interface) {
            addProblem(
                templateImplementsSuperClass.withArguments(interface.name),
                charOffset,
                noLength);
          } else if (implemented.contains(interface)) {
            // Aggregate repetitions.
            problems ??= new Map<ClassBuilder, int>();
            problems[interface] ??= 0;
            problems[interface] += 1;

            problemsOffsets ??= new Map<ClassBuilder, int>();
            problemsOffsets[interface] ??= charOffset;
          } else if (interface.target == coreTypes.futureOrClass) {
            addProblem(messageImplementsFutureOr, charOffset,
                interface.target.name.length);
          } else {
            implemented.add(interface);
          }
        }
      }
    }
    if (problems != null) {
      problems.forEach((ClassBuilder interface, int repetitions) {
        addProblem(
            templateImplementsRepeated.withArguments(
                interface.name, repetitions),
            problemsOffsets[interface],
            noLength);
      });
    }
  }

  @override
  int resolveConstructors(LibraryBuilder library) {
    int count = super.resolveConstructors(library);
    if (count != 0) {
      Map<String, MemberBuilder> constructors = this.constructors.local;
      // Copy keys to avoid concurrent modification error.
      List<String> names = constructors.keys.toList();
      for (String name in names) {
        Declaration declaration = constructors[name];
        if (declaration.parent != this) {
          unexpected(
              "$fileUri", "${declaration.parent.fileUri}", charOffset, fileUri);
        }
        if (declaration is KernelRedirectingFactoryBuilder) {
          // Compute the immediate redirection target, not the effective.
          ConstructorReferenceBuilder redirectionTarget =
              declaration.redirectionTarget;
          if (redirectionTarget != null) {
            Declaration targetBuilder = redirectionTarget.target;
            addRedirectingConstructor(declaration, library);
            if (targetBuilder is ProcedureBuilder) {
              List<DartType> typeArguments = declaration.typeArguments;
              if (typeArguments == null) {
                // TODO(32049) If type arguments aren't specified, they should
                // be inferred.  Currently, the inference is not performed.
                // The code below is a workaround.
                typeArguments = new List<DartType>.filled(
                    targetBuilder.target.enclosingClass.typeParameters.length,
                    const DynamicType(),
                    growable: true);
              }
              declaration.setRedirectingFactoryBody(
                  targetBuilder.target, typeArguments);
            } else if (targetBuilder is DillMemberBuilder) {
              List<DartType> typeArguments = declaration.typeArguments;
              if (typeArguments == null) {
                // TODO(32049) If type arguments aren't specified, they should
                // be inferred.  Currently, the inference is not performed.
                // The code below is a workaround.
                typeArguments = new List<DartType>.filled(
                    targetBuilder.target.enclosingClass.typeParameters.length,
                    const DynamicType(),
                    growable: true);
              }
              declaration.setRedirectingFactoryBody(
                  targetBuilder.member, typeArguments);
            } else {
              Message message = templateRedirectionTargetNotFound
                  .withArguments(redirectionTarget.fullNameForErrors);
              if (declaration.isConst) {
                addProblem(message, declaration.charOffset, noLength);
              } else {
                addProblem(message, declaration.charOffset, noLength);
              }
              // CoreTypes aren't computed yet, and this is the outline
              // phase. So we can't and shouldn't create a method body.
              declaration.body = new RedirectingFactoryBody.unresolved(
                  redirectionTarget.fullNameForErrors);
            }
          }
        }
      }
    }
    return count;
  }

  void addRedirectingConstructor(
      KernelProcedureBuilder constructor, KernelLibraryBuilder library) {
    // Add a new synthetic field to this class for representing factory
    // constructors. This is used to support resolving such constructors in
    // source code.
    //
    // The synthetic field looks like this:
    //
    //     final _redirecting# = [c1, ..., cn];
    //
    // Where each c1 ... cn are an instance of [StaticGet] whose target is
    // [constructor.target].
    //
    // TODO(ahe): Add a kernel node to represent redirecting factory bodies.
    DillMemberBuilder constructorsField =
        origin.scope.local.putIfAbsent("_redirecting#", () {
      ListLiteral literal = new ListLiteral(<Expression>[]);
      Name name = new Name("_redirecting#", library.library);
      Field field = new Field(name,
          isStatic: true, initializer: literal, fileUri: cls.fileUri)
        ..fileOffset = cls.fileOffset;
      cls.addMember(field);
      return new DillMemberBuilder(field, this);
    });
    Field field = constructorsField.target;
    ListLiteral literal = field.initializer;
    literal.expressions
        .add(new StaticGet(constructor.target)..parent = literal);
  }

  void checkOverrides(
      ClassHierarchy hierarchy, TypeEnvironment typeEnvironment) {
    handleSeenCovariant(
        Member declaredMember,
        Member interfaceMember,
        bool isSetter,
        callback(
            Member declaredMember, Member interfaceMember, bool isSetter)) {
      // When a parameter is covariant we have to check that we also
      // override the same member in all parents.
      for (Supertype supertype in interfaceMember.enclosingClass.supers) {
        Member m = hierarchy.getInterfaceMember(
            supertype.classNode, interfaceMember.name,
            setter: isSetter);
        if (m != null) {
          callback(declaredMember, m, isSetter);
        }
      }
    }

    overridePairCallback(
        Member declaredMember, Member interfaceMember, bool isSetter) {
      if (declaredMember is Constructor || interfaceMember is Constructor) {
        unimplemented("Constructor in override check.",
            declaredMember.fileOffset, fileUri);
      }
      if (declaredMember is Procedure && interfaceMember is Procedure) {
        if (declaredMember.kind == ProcedureKind.Method &&
            interfaceMember.kind == ProcedureKind.Method) {
          bool seenCovariant = checkMethodOverride(
              hierarchy, typeEnvironment, declaredMember, interfaceMember);
          if (seenCovariant) {
            handleSeenCovariant(declaredMember, interfaceMember, isSetter,
                overridePairCallback);
          }
        }
        if (declaredMember.kind == ProcedureKind.Getter &&
            interfaceMember.kind == ProcedureKind.Getter) {
          checkGetterOverride(
              hierarchy, typeEnvironment, declaredMember, interfaceMember);
        }
        if (declaredMember.kind == ProcedureKind.Setter &&
            interfaceMember.kind == ProcedureKind.Setter) {
          bool seenCovariant = checkSetterOverride(
              hierarchy, typeEnvironment, declaredMember, interfaceMember);
          if (seenCovariant) {
            handleSeenCovariant(declaredMember, interfaceMember, isSetter,
                overridePairCallback);
          }
        }
      } else {
        bool declaredMemberHasGetter = declaredMember is Field ||
            declaredMember is Procedure && declaredMember.isGetter;
        bool interfaceMemberHasGetter = interfaceMember is Field ||
            interfaceMember is Procedure && interfaceMember.isGetter;
        bool declaredMemberHasSetter = declaredMember is Field ||
            declaredMember is Procedure && declaredMember.isSetter;
        bool interfaceMemberHasSetter = interfaceMember is Field ||
            interfaceMember is Procedure && interfaceMember.isSetter;
        if (declaredMemberHasGetter && interfaceMemberHasGetter) {
          checkGetterOverride(
              hierarchy, typeEnvironment, declaredMember, interfaceMember);
        } else if (declaredMemberHasSetter && interfaceMemberHasSetter) {
          bool seenCovariant = checkSetterOverride(
              hierarchy, typeEnvironment, declaredMember, interfaceMember);
          if (seenCovariant) {
            handleSeenCovariant(declaredMember, interfaceMember, isSetter,
                overridePairCallback);
          }
        }
      }
      // TODO(ahe): Handle other cases: accessors, operators, and fields.
    }

    hierarchy.forEachOverridePair(cls, overridePairCallback);
  }

  void checkAbstractMembers(CoreTypes coreTypes, ClassHierarchy hierarchy) {
    if (isAbstract) {
      // Unimplemented members allowed
      return;
    }

    List<LocatedMessage> context = null;

    bool mustHaveImplementation(Member member) {
      // Public member
      if (!member.name.isPrivate) return true;
      // Private member in different library
      if (member.enclosingLibrary != cls.enclosingLibrary) return false;
      // Private member in patch
      if (member.fileUri != member.enclosingClass.fileUri) return false;
      // Private member in same library
      return true;
    }

    bool isValidImplementation(Member interfaceMember, Member dispatchTarget,
        {bool setters}) {
      // If they're the exact same it's valid.
      if (interfaceMember == dispatchTarget) return true;

      if (interfaceMember is Procedure && dispatchTarget is Procedure) {
        // E.g. getter vs method.
        if (interfaceMember.kind != dispatchTarget.kind) return false;

        if (dispatchTarget.function.positionalParameters.length <
                interfaceMember.function.requiredParameterCount ||
            dispatchTarget.function.positionalParameters.length <
                interfaceMember.function.positionalParameters.length)
          return false;

        if (interfaceMember.function.requiredParameterCount <
            dispatchTarget.function.requiredParameterCount) return false;

        if (dispatchTarget.function.namedParameters.length <
            interfaceMember.function.namedParameters.length) return false;

        // Two Procedures of the same kind with the same number of parameters.
        return true;
      }

      if ((interfaceMember is Field || interfaceMember is Procedure) &&
          (dispatchTarget is Field || dispatchTarget is Procedure)) {
        if (setters) {
          bool interfaceMemberHasSetter =
              (interfaceMember is Field && interfaceMember.hasSetter) ||
                  interfaceMember is Procedure && interfaceMember.isSetter;
          bool dispatchTargetHasSetter =
              (dispatchTarget is Field && dispatchTarget.hasSetter) ||
                  dispatchTarget is Procedure && dispatchTarget.isSetter;
          // Combination of (settable) field and/or (procedure) setter is valid.
          return interfaceMemberHasSetter && dispatchTargetHasSetter;
        } else {
          bool interfaceMemberHasGetter = interfaceMember is Field ||
              interfaceMember is Procedure && interfaceMember.isGetter;
          bool dispatchTargetHasGetter = dispatchTarget is Field ||
              dispatchTarget is Procedure && dispatchTarget.isGetter;
          // Combination of field and/or (procedure) getter is valid.
          return interfaceMemberHasGetter && dispatchTargetHasGetter;
        }
      }

      return unhandled(
          "${interfaceMember.runtimeType} and ${dispatchTarget.runtimeType}",
          "isValidImplementation",
          interfaceMember.fileOffset,
          interfaceMember.fileUri);
    }

    bool hasNoSuchMethod =
        hierarchy.getDispatchTarget(cls, noSuchMethodName).enclosingClass !=
            coreTypes.objectClass;

    void findMissingImplementations({bool setters}) {
      List<Member> dispatchTargets =
          hierarchy.getDispatchTargets(cls, setters: setters);
      int targetIndex = 0;
      for (Member interfaceMember
          in hierarchy.getInterfaceMembers(cls, setters: setters)) {
        if (mustHaveImplementation(interfaceMember)) {
          while (targetIndex < dispatchTargets.length &&
              ClassHierarchy.compareMembers(
                      dispatchTargets[targetIndex], interfaceMember) <
                  0) {
            targetIndex++;
          }
          bool foundTarget = targetIndex < dispatchTargets.length &&
              ClassHierarchy.compareMembers(
                      dispatchTargets[targetIndex], interfaceMember) <=
                  0;
          bool hasProblem = true;
          if (foundTarget &&
              isValidImplementation(
                  interfaceMember, dispatchTargets[targetIndex],
                  setters: setters)) hasProblem = false;
          if (hasNoSuchMethod && !foundTarget) hasProblem = false;
          if (hasProblem) {
            Name name = interfaceMember.name;
            String displayName = name.name + (setters ? "=" : "");
            if (interfaceMember is Procedure &&
                interfaceMember.isSyntheticForwarder) {
              Procedure forwarder = interfaceMember;
              interfaceMember = forwarder.forwardingStubInterfaceTarget;
            }
            context ??= <LocatedMessage>[];
            context.add(templateMissingImplementationCause
                .withArguments(displayName)
                .withLocation(interfaceMember.fileUri,
                    interfaceMember.fileOffset, name.name.length));
          }
        }
      }
    }

    findMissingImplementations(setters: false);
    findMissingImplementations(setters: true);

    if (context?.isNotEmpty ?? false) {
      String memberString =
          context.map((message) => "'${message.arguments["name"]}'").join(", ");
      library.addProblem(
          templateMissingImplementationNotAbstract.withArguments(
              cls.name, memberString),
          cls.fileOffset,
          cls.name.length,
          cls.fileUri,
          context: context);
    }
  }

  bool hasUserDefinedNoSuchMethod(
      Class klass, ClassHierarchy hierarchy, Class objectClass) {
    Member noSuchMethod = hierarchy.getDispatchTarget(klass, noSuchMethodName);
    return noSuchMethod != null && noSuchMethod.enclosingClass != objectClass;
  }

  void transformProcedureToNoSuchMethodForwarder(
      Member noSuchMethodInterface, KernelTarget target, Procedure procedure) {
    String prefix =
        procedure.isGetter ? 'get:' : procedure.isSetter ? 'set:' : '';
    Expression invocation = target.backendTarget.instantiateInvocation(
        target.loader.coreTypes,
        new ThisExpression(),
        prefix + procedure.name.name,
        new Arguments.forwarded(procedure.function),
        procedure.fileOffset,
        /*isSuper=*/ false);
    Expression result = new MethodInvocation(new ThisExpression(),
        noSuchMethodName, new Arguments([invocation]), noSuchMethodInterface)
      ..fileOffset = procedure.fileOffset;
    if (procedure.function.returnType is! VoidType) {
      result = new AsExpression(result, procedure.function.returnType)
        ..isTypeError = true
        ..fileOffset = procedure.fileOffset;
    }
    procedure.function.body = new ReturnStatement(result)
      ..fileOffset = procedure.fileOffset;
    procedure.function.body.parent = procedure.function;

    procedure.isAbstract = false;
    procedure.isNoSuchMethodForwarder = true;
    procedure.isForwardingStub = false;
    procedure.isForwardingSemiStub = false;
  }

  void addNoSuchMethodForwarderForProcedure(Member noSuchMethod,
      KernelTarget target, Procedure procedure, ClassHierarchy hierarchy) {
    CloneWithoutBody cloner = new CloneWithoutBody(
        typeSubstitution: getSubstitutionMap(
            hierarchy.getClassAsInstanceOf(cls, procedure.enclosingClass)),
        cloneAnnotations: false);
    Procedure cloned = cloner.clone(procedure)..isExternal = false;
    transformProcedureToNoSuchMethodForwarder(noSuchMethod, target, cloned);
    cls.procedures.add(cloned);
    cloned.parent = cls;

    KernelLibraryBuilder library = this.library;
    library.forwardersOrigins.add(cloned);
    library.forwardersOrigins.add(procedure);
  }

  void addNoSuchMethodForwarderGetterForField(Member noSuchMethod,
      KernelTarget target, Field field, ClassHierarchy hierarchy) {
    Substitution substitution = Substitution.fromSupertype(
        hierarchy.getClassAsInstanceOf(cls, field.enclosingClass));
    Procedure getter = new Procedure(
        field.name,
        ProcedureKind.Getter,
        new FunctionNode(null,
            typeParameters: <TypeParameter>[],
            positionalParameters: <VariableDeclaration>[],
            namedParameters: <VariableDeclaration>[],
            requiredParameterCount: 0,
            returnType: substitution.substituteType(field.type)),
        fileUri: field.fileUri)
      ..fileOffset = field.fileOffset;
    transformProcedureToNoSuchMethodForwarder(noSuchMethod, target, getter);
    cls.procedures.add(getter);
    getter.parent = cls;
  }

  void addNoSuchMethodForwarderSetterForField(Member noSuchMethod,
      KernelTarget target, Field field, ClassHierarchy hierarchy) {
    Substitution substitution = Substitution.fromSupertype(
        hierarchy.getClassAsInstanceOf(cls, field.enclosingClass));
    Procedure setter = new Procedure(
        field.name,
        ProcedureKind.Setter,
        new FunctionNode(null,
            typeParameters: <TypeParameter>[],
            positionalParameters: <VariableDeclaration>[
              new VariableDeclaration("value",
                  type: substitution.substituteType(field.type))
            ],
            namedParameters: <VariableDeclaration>[],
            requiredParameterCount: 1,
            returnType: const VoidType()),
        fileUri: field.fileUri)
      ..fileOffset = field.fileOffset;
    transformProcedureToNoSuchMethodForwarder(noSuchMethod, target, setter);
    cls.procedures.add(setter);
    setter.parent = cls;
  }

  /// Adds noSuchMethod forwarding stubs to this class. Returns `true` if the
  /// class was modified.
  bool addNoSuchMethodForwarders(
      KernelTarget target, ClassHierarchy hierarchy) {
    if (cls.isAbstract ||
        !hasUserDefinedNoSuchMethod(cls, hierarchy, target.objectClass)) {
      return false;
    }

    Set<Name> existingForwardersNames = new Set<Name>();
    Set<Name> existingSetterForwardersNames = new Set<Name>();
    Class leastConcreteSuperclass = cls.superclass;
    while (
        leastConcreteSuperclass != null && leastConcreteSuperclass.isAbstract) {
      leastConcreteSuperclass = leastConcreteSuperclass.superclass;
    }
    if (leastConcreteSuperclass != null &&
        hasUserDefinedNoSuchMethod(
            leastConcreteSuperclass, hierarchy, target.objectClass)) {
      List<Member> concrete =
          hierarchy.getDispatchTargets(leastConcreteSuperclass);
      for (Member member
          in hierarchy.getInterfaceMembers(leastConcreteSuperclass)) {
        if (ClassHierarchy.findMemberByName(concrete, member.name) == null) {
          existingForwardersNames.add(member.name);
        }
      }

      List<Member> concreteSetters =
          hierarchy.getDispatchTargets(leastConcreteSuperclass, setters: true);
      for (Member member in hierarchy
          .getInterfaceMembers(leastConcreteSuperclass, setters: true)) {
        if (ClassHierarchy.findMemberByName(concreteSetters, member.name) ==
            null) {
          existingSetterForwardersNames.add(member.name);
        }
      }
    }

    Member noSuchMethod = ClassHierarchy.findMemberByName(
        hierarchy.getInterfaceMembers(cls), noSuchMethodName);

    List<Member> concrete = hierarchy.getDispatchTargets(cls);
    List<Member> declared = hierarchy.getDeclaredMembers(cls);

    bool changed = false;
    for (Member member in hierarchy.getInterfaceMembers(cls)) {
      if (member is Procedure &&
          ClassHierarchy.findMemberByName(concrete, member.name) == null &&
          !existingForwardersNames.contains(member.name)) {
        if (ClassHierarchy.findMemberByName(declared, member.name) != null) {
          transformProcedureToNoSuchMethodForwarder(
              noSuchMethod, target, member);
        } else {
          addNoSuchMethodForwarderForProcedure(
              noSuchMethod, target, member, hierarchy);
        }
        existingForwardersNames.add(member.name);
        changed = true;
      }
      if (member is Field &&
          ClassHierarchy.findMemberByName(concrete, member.name) == null &&
          !existingForwardersNames.contains(member.name)) {
        addNoSuchMethodForwarderGetterForField(
            noSuchMethod, target, member, hierarchy);
        existingForwardersNames.add(member.name);
        changed = true;
      }
    }

    List<Member> concreteSetters =
        hierarchy.getDispatchTargets(cls, setters: true);
    List<Member> declaredSetters =
        hierarchy.getDeclaredMembers(cls, setters: true);
    for (Member member in hierarchy.getInterfaceMembers(cls, setters: true)) {
      if (member is Procedure &&
          ClassHierarchy.findMemberByName(concreteSetters, member.name) ==
              null &&
          !existingSetterForwardersNames.contains(member.name)) {
        if (ClassHierarchy.findMemberByName(declaredSetters, member.name) !=
            null) {
          transformProcedureToNoSuchMethodForwarder(
              noSuchMethod, target, member);
        } else {
          addNoSuchMethodForwarderForProcedure(
              noSuchMethod, target, member, hierarchy);
        }
        existingSetterForwardersNames.add(member.name);
        changed = true;
      }
      if (member is Field &&
          ClassHierarchy.findMemberByName(concreteSetters, member.name) ==
              null &&
          !existingSetterForwardersNames.contains(member.name)) {
        addNoSuchMethodForwarderSetterForField(
            noSuchMethod, target, member, hierarchy);
        existingSetterForwardersNames.add(member.name);
        changed = true;
      }
    }

    return changed;
  }

  Uri _getMemberUri(Member member) {
    if (member is Field) return member.fileUri;
    if (member is Procedure) return member.fileUri;
    // Other member types won't be seen because constructors don't participate
    // in override relationships
    return unhandled('${member.runtimeType}', '_getMemberUri', -1, null);
  }

  Substitution _computeInterfaceSubstitution(
      ClassHierarchy hierarchy,
      Member declaredMember,
      Member interfaceMember,
      FunctionNode declaredFunction,
      FunctionNode interfaceFunction) {
    Substitution interfaceSubstitution;
    if (interfaceMember.enclosingClass.typeParameters.isNotEmpty) {
      interfaceSubstitution = Substitution.fromSupertype(
          hierarchy.getClassAsInstanceOf(cls, interfaceMember.enclosingClass));
    }
    if (declaredFunction?.typeParameters?.length !=
        interfaceFunction?.typeParameters?.length) {
      addProblem(
          templateOverrideTypeVariablesMismatch.withArguments(
              "$name::${declaredMember.name.name}",
              "${interfaceMember.enclosingClass.name}::"
              "${interfaceMember.name.name}"),
          declaredMember.fileOffset,
          noLength,
          context: [
            templateOverriddenMethodCause
                .withArguments(interfaceMember.name.name)
                .withLocation(_getMemberUri(interfaceMember),
                    interfaceMember.fileOffset, noLength)
          ]);
    } else if (library.loader.target.backendTarget.strongMode &&
        declaredFunction?.typeParameters != null) {
      Map<TypeParameter, DartType> substitutionMap =
          <TypeParameter, DartType>{};
      for (int i = 0; i < declaredFunction.typeParameters.length; ++i) {
        substitutionMap[interfaceFunction.typeParameters[i]] =
            new TypeParameterType(declaredFunction.typeParameters[i]);
      }
      Substitution substitution = Substitution.fromMap(substitutionMap);
      for (int i = 0; i < declaredFunction.typeParameters.length; ++i) {
        TypeParameter declaredParameter = declaredFunction.typeParameters[i];
        TypeParameter interfaceParameter = interfaceFunction.typeParameters[i];
        if (!interfaceParameter.isGenericCovariantImpl) {
          DartType declaredBound = declaredParameter.bound;
          DartType interfaceBound = interfaceParameter.bound;
          if (interfaceSubstitution != null) {
            declaredBound = interfaceSubstitution.substituteType(declaredBound);
            interfaceBound =
                interfaceSubstitution.substituteType(interfaceBound);
          }
          if (declaredBound != substitution.substituteType(interfaceBound)) {
            addProblem(
                templateOverrideTypeVariablesMismatch.withArguments(
                    "$name::${declaredMember.name.name}",
                    "${interfaceMember.enclosingClass.name}::"
                    "${interfaceMember.name.name}"),
                declaredMember.fileOffset,
                noLength,
                context: [
                  templateOverriddenMethodCause
                      .withArguments(interfaceMember.name.name)
                      .withLocation(_getMemberUri(interfaceMember),
                          interfaceMember.fileOffset, noLength)
                ]);
          }
        }
      }
      interfaceSubstitution = interfaceSubstitution == null
          ? substitution
          : Substitution.combine(interfaceSubstitution, substitution);
    }
    return interfaceSubstitution;
  }

  bool _checkTypes(
      TypeEnvironment typeEnvironment,
      Substitution interfaceSubstitution,
      Member declaredMember,
      Member interfaceMember,
      DartType declaredType,
      DartType interfaceType,
      bool isCovariant,
      VariableDeclaration declaredParameter,
      {bool asIfDeclaredParameter = false}) {
    if (!library.loader.target.backendTarget.strongMode) return false;

    if (interfaceSubstitution != null) {
      interfaceType = interfaceSubstitution.substituteType(interfaceType);
    }

    bool inParameter = declaredParameter != null || asIfDeclaredParameter;
    DartType subtype = inParameter ? interfaceType : declaredType;
    DartType supertype = inParameter ? declaredType : interfaceType;

    if (typeEnvironment.isSubtypeOf(subtype, supertype)) {
      // No problem--the proper subtyping relation is satisfied.
    } else if (isCovariant && typeEnvironment.isSubtypeOf(supertype, subtype)) {
      // No problem--the overriding parameter is marked "covariant" and has
      // a type which is a subtype of the parameter it overrides.
    } else {
      // Report an error.
      // TODO(ahe): The double-colon notation shouldn't be used in error
      // messages.
      String declaredMemberName = '$name::${declaredMember.name.name}';
      Message message;
      int fileOffset;
      if (declaredParameter == null) {
        message = templateOverrideTypeMismatchReturnType.withArguments(
            declaredMemberName, declaredType, interfaceType);
        fileOffset = declaredMember.fileOffset;
      } else {
        message = templateOverrideTypeMismatchParameter.withArguments(
            declaredParameter.name,
            declaredMemberName,
            declaredType,
            interfaceType);
        fileOffset = declaredParameter.fileOffset;
      }
      library.addProblem(message, fileOffset, noLength, fileUri, context: [
        templateOverriddenMethodCause
            .withArguments(interfaceMember.name.name)
            .withLocation(_getMemberUri(interfaceMember),
                interfaceMember.fileOffset, noLength)
      ]);
      return true;
    }
    return false;
  }

  /// Returns whether a covariant parameter was seen and more methods thus have
  /// to be checked.
  bool checkMethodOverride(
      ClassHierarchy hierarchy,
      TypeEnvironment typeEnvironment,
      Procedure declaredMember,
      Procedure interfaceMember) {
    if (declaredMember.enclosingClass != cls) {
      // TODO(ahe): Include these checks as well, but the message needs to
      // explain that [declaredMember] is inherited.
      return false;
    }
    assert(declaredMember.kind == ProcedureKind.Method);
    assert(interfaceMember.kind == ProcedureKind.Method);
    bool seenCovariant = false;
    FunctionNode declaredFunction = declaredMember.function;
    FunctionNode interfaceFunction = interfaceMember.function;

    Substitution interfaceSubstitution = _computeInterfaceSubstitution(
        hierarchy,
        declaredMember,
        interfaceMember,
        declaredFunction,
        interfaceFunction);

    _checkTypes(
        typeEnvironment,
        interfaceSubstitution,
        declaredMember,
        interfaceMember,
        declaredFunction.returnType,
        interfaceFunction.returnType,
        false,
        null);
    if (declaredFunction.positionalParameters.length <
            interfaceFunction.requiredParameterCount ||
        declaredFunction.positionalParameters.length <
            interfaceFunction.positionalParameters.length) {
      addProblem(
          templateOverrideFewerPositionalArguments.withArguments(
              "$name::${declaredMember.name.name}",
              "${interfaceMember.enclosingClass.name}::"
              "${interfaceMember.name.name}"),
          declaredMember.fileOffset,
          noLength,
          context: [
            templateOverriddenMethodCause
                .withArguments(interfaceMember.name.name)
                .withLocation(interfaceMember.fileUri,
                    interfaceMember.fileOffset, noLength)
          ]);
    }
    if (interfaceFunction.requiredParameterCount <
        declaredFunction.requiredParameterCount) {
      addProblem(
          templateOverrideMoreRequiredArguments.withArguments(
              "$name::${declaredMember.name.name}",
              "${interfaceMember.enclosingClass.name}::"
              "${interfaceMember.name.name}"),
          declaredMember.fileOffset,
          noLength,
          context: [
            templateOverriddenMethodCause
                .withArguments(interfaceMember.name.name)
                .withLocation(interfaceMember.fileUri,
                    interfaceMember.fileOffset, noLength)
          ]);
    }
    for (int i = 0;
        i < declaredFunction.positionalParameters.length &&
            i < interfaceFunction.positionalParameters.length;
        i++) {
      var declaredParameter = declaredFunction.positionalParameters[i];
      _checkTypes(
          typeEnvironment,
          interfaceSubstitution,
          declaredMember,
          interfaceMember,
          declaredParameter.type,
          interfaceFunction.positionalParameters[i].type,
          declaredParameter.isCovariant,
          declaredParameter);
      if (declaredParameter.isCovariant) seenCovariant = true;
    }
    if (declaredFunction.namedParameters.isEmpty &&
        interfaceFunction.namedParameters.isEmpty) {
      return seenCovariant;
    }
    if (declaredFunction.namedParameters.length <
        interfaceFunction.namedParameters.length) {
      addProblem(
          templateOverrideFewerNamedArguments.withArguments(
              "$name::${declaredMember.name.name}",
              "${interfaceMember.enclosingClass.name}::"
              "${interfaceMember.name.name}"),
          declaredMember.fileOffset,
          noLength,
          context: [
            templateOverriddenMethodCause
                .withArguments(interfaceMember.name.name)
                .withLocation(interfaceMember.fileUri,
                    interfaceMember.fileOffset, noLength)
          ]);
    }
    int compareNamedParameters(VariableDeclaration p0, VariableDeclaration p1) {
      return p0.name.compareTo(p1.name);
    }

    List<VariableDeclaration> sortedFromDeclared =
        new List.from(declaredFunction.namedParameters)
          ..sort(compareNamedParameters);
    List<VariableDeclaration> sortedFromInterface =
        new List.from(interfaceFunction.namedParameters)
          ..sort(compareNamedParameters);
    Iterator<VariableDeclaration> declaredNamedParameters =
        sortedFromDeclared.iterator;
    Iterator<VariableDeclaration> interfaceNamedParameters =
        sortedFromInterface.iterator;
    outer:
    while (declaredNamedParameters.moveNext() &&
        interfaceNamedParameters.moveNext()) {
      while (declaredNamedParameters.current.name !=
          interfaceNamedParameters.current.name) {
        if (!declaredNamedParameters.moveNext()) {
          addProblem(
              templateOverrideMismatchNamedParameter.withArguments(
                  "$name::${declaredMember.name.name}",
                  interfaceNamedParameters.current.name,
                  "${interfaceMember.enclosingClass.name}::"
                  "${interfaceMember.name.name}"),
              declaredMember.fileOffset,
              noLength,
              context: [
                templateOverriddenMethodCause
                    .withArguments(interfaceMember.name.name)
                    .withLocation(interfaceMember.fileUri,
                        interfaceMember.fileOffset, noLength)
              ]);
          break outer;
        }
      }
      var declaredParameter = declaredNamedParameters.current;
      _checkTypes(
          typeEnvironment,
          interfaceSubstitution,
          declaredMember,
          interfaceMember,
          declaredParameter.type,
          interfaceNamedParameters.current.type,
          declaredParameter.isCovariant,
          declaredParameter);
      if (declaredParameter.isCovariant) seenCovariant = true;
    }
    return seenCovariant;
  }

  void checkGetterOverride(
      ClassHierarchy hierarchy,
      TypeEnvironment typeEnvironment,
      Member declaredMember,
      Member interfaceMember) {
    if (declaredMember.enclosingClass != cls) {
      // TODO(paulberry): Include these checks as well, but the message needs to
      // explain that [declaredMember] is inherited.
      return;
    }
    Substitution interfaceSubstitution = _computeInterfaceSubstitution(
        hierarchy, declaredMember, interfaceMember, null, null);
    var declaredType = declaredMember.getterType;
    var interfaceType = interfaceMember.getterType;
    _checkTypes(typeEnvironment, interfaceSubstitution, declaredMember,
        interfaceMember, declaredType, interfaceType, false, null);
  }

  /// Returns whether a covariant parameter was seen and more methods thus have
  /// to be checked.
  bool checkSetterOverride(
      ClassHierarchy hierarchy,
      TypeEnvironment typeEnvironment,
      Member declaredMember,
      Member interfaceMember) {
    if (declaredMember.enclosingClass != cls) {
      // TODO(paulberry): Include these checks as well, but the message needs to
      // explain that [declaredMember] is inherited.
      return false;
    }
    Substitution interfaceSubstitution = _computeInterfaceSubstitution(
        hierarchy, declaredMember, interfaceMember, null, null);
    var declaredType = declaredMember.setterType;
    var interfaceType = interfaceMember.setterType;
    var declaredParameter =
        declaredMember.function?.positionalParameters?.elementAt(0);
    bool isCovariant = declaredParameter?.isCovariant ?? false;
    if (declaredMember is Field) isCovariant = declaredMember.isCovariant;
    _checkTypes(
        typeEnvironment,
        interfaceSubstitution,
        declaredMember,
        interfaceMember,
        declaredType,
        interfaceType,
        isCovariant,
        declaredParameter,
        asIfDeclaredParameter: true);
    return isCovariant;
  }

  String get fullNameForErrors {
    return isMixinApplication
        ? "${supertype.fullNameForErrors} with ${mixedInType.fullNameForErrors}"
        : name;
  }

  @override
  void applyPatch(Declaration patch) {
    if (patch is KernelClassBuilder) {
      patch.actualOrigin = this;
      // TODO(ahe): Complain if `patch.supertype` isn't null.
      scope.local.forEach((String name, Declaration member) {
        Declaration memberPatch = patch.scope.local[name];
        if (memberPatch != null) {
          member.applyPatch(memberPatch);
        }
      });
      scope.setters.forEach((String name, Declaration member) {
        Declaration memberPatch = patch.scope.setters[name];
        if (memberPatch != null) {
          member.applyPatch(memberPatch);
        }
      });
      constructors.local.forEach((String name, Declaration member) {
        Declaration memberPatch = patch.constructors.local[name];
        if (memberPatch != null) {
          member.applyPatch(memberPatch);
        }
      });

      int originLength = typeVariables?.length ?? 0;
      int patchLength = patch.typeVariables?.length ?? 0;
      if (originLength != patchLength) {
        patch.addProblem(messagePatchClassTypeVariablesMismatch,
            patch.charOffset, noLength, context: [
          messagePatchClassOrigin.withLocation(fileUri, charOffset, noLength)
        ]);
      } else if (typeVariables != null) {
        int count = 0;
        for (KernelTypeVariableBuilder t in patch.typeVariables) {
          typeVariables[count++].applyPatch(t);
        }
      }
    } else {
      library.addProblem(messagePatchDeclarationMismatch, patch.charOffset,
          noLength, patch.fileUri, context: [
        messagePatchDeclarationOrigin.withLocation(
            fileUri, charOffset, noLength)
      ]);
    }
  }

  @override
  Declaration findStaticBuilder(
      String name, int charOffset, Uri fileUri, LibraryBuilder accessingLibrary,
      {bool isSetter: false}) {
    Declaration declaration = super.findStaticBuilder(
        name, charOffset, fileUri, accessingLibrary,
        isSetter: isSetter);
    if (declaration == null && isPatch) {
      return origin.findStaticBuilder(
          name, charOffset, fileUri, accessingLibrary,
          isSetter: isSetter);
    }
    return declaration;
  }

  @override
  Declaration findConstructorOrFactory(
      String name, int charOffset, Uri uri, LibraryBuilder accessingLibrary) {
    Declaration declaration =
        super.findConstructorOrFactory(name, charOffset, uri, accessingLibrary);
    if (declaration == null && isPatch) {
      return origin.findConstructorOrFactory(
          name, charOffset, uri, accessingLibrary);
    }
    return declaration;
  }

  // Computes the function type of a given redirection target. Returns [null] if
  // the type of actual target could not be computed.
  FunctionType computeRedirecteeType(
      ConstructorReferenceBuilder redirectionTarget,
      TypeEnvironment typeEnvironment) {
    FunctionNode target;
    bool isConstructor = false;
    Class targetClass; // Used when the redirection target is a constructor.
    if (redirectionTarget.target is KernelFunctionBuilder) {
      KernelFunctionBuilder targetBuilder = redirectionTarget.target;
      target = targetBuilder.function;
      isConstructor = targetBuilder.isConstructor;
      if (isConstructor) {
        targetClass = targetBuilder.parent.target;
      }
    } else if (redirectionTarget.target is DillMemberBuilder &&
        (redirectionTarget.target.isConstructor ||
            redirectionTarget.target.isFactory)) {
      DillMemberBuilder targetBuilder = redirectionTarget.target;
      // It seems that the [redirectionTarget.target] is an instance of
      // [DillMemberBuilder] whenever the redirectee is an implicit constructor,
      // e.g.
      //
      //   class A {
      //     factory A() = B;
      //   }
      //   class B implements A {}
      //
      target = targetBuilder.member.function;
      isConstructor = targetBuilder.isConstructor;
      if (isConstructor) {
        targetClass = targetBuilder.member.enclosingClass;
      }
    } else {
      return null;
    }

    FunctionType inferredType = target.functionType;
    if (redirectionTarget.typeArguments != null &&
        inferredType.typeParameters.length !=
            redirectionTarget.typeArguments.length) {
      addProblem(
          templateTypeArgumentMismatch
              .withArguments(inferredType.typeParameters.length),
          redirectionTarget.charOffset,
          noLength);
      return null;
    }

    // Compute the substitution of the target class type parameters if
    // [redirectionTarget] has any type arguments. Any built type arguments are
    // stored in [typeArguments] for later use.
    Substitution substitution;
    List<DartType> typeArguments;
    if (redirectionTarget.typeArguments != null &&
        redirectionTarget.typeArguments.length > 0) {
      typeArguments = new List<DartType>();
      for (var i = 0; i < inferredType.typeParameters.length; i++) {
        var typeParameter = inferredType.typeParameters[i];
        var typeArgument = redirectionTarget.typeArguments[i].build(library);
        // Check whether the [typeArgument] respects the bounds of [typeParameter].
        if (typeArgument is TypeParameterType) {
          if (!typeEnvironment.isSubtypeOf(
              typeArgument.bound, typeParameter.bound)) {
            // TODO(hillerstrom): Use dmitrays' error message once his "bounds
            // checking" CL has landed.
            addProblem(
                templateRedirectingFactoryIncompatibleBounds.withArguments(
                    typeArgument.parameter.name,
                    typeArgument.bound,
                    typeParameter.bound),
                redirectionTarget.charOffset,
                noLength);
            return null;
          }
        }
        typeArguments.add(typeArgument);
      }
      substitution =
          Substitution.fromPairs(inferredType.typeParameters, typeArguments);
    } else if (redirectionTarget.typeArguments == null &&
        inferredType.typeParameters.length > 0) {
      // TODO(hillerstrom): In this case, we need to perform type inference on
      // the redirectee to obtain actual type arguments which would allow the
      // following program to type check:
      //
      //    class A<T> {
      //       factory A() = B;
      //    }
      //    class B<T> implements A<T> {
      //       B();
      //    }
      //
      return null;
    }

    FunctionType redirecteeType;
    // If the target is a constructor then we need to patch the return type of
    // the inferred type, because the type inferrer always infers the return
    // type to be "void", whereas the inferred return type of a factory is its
    // enclosing class. TODO(hillerstrom): It may be worthwhile to change the
    // typing of constructors such that the return type is its enclosing class.
    if (isConstructor) {
      DartType returnType =
          new InterfaceType(targetClass, typeArguments ?? const <DartType>[]);

      redirecteeType = new FunctionType(
          inferredType.positionalParameters, returnType,
          namedParameters: inferredType.namedParameters,
          typeParameters: inferredType.typeParameters,
          requiredParameterCount: inferredType.requiredParameterCount);
    } else {
      redirecteeType = inferredType;
    }

    // Substitute if necessary.
    redirecteeType = substitution == null
        ? redirecteeType
        : (substitution.substituteType(redirecteeType.withoutTypeParameters)
            as FunctionType);

    return redirecteeType;
  }

  String computeRedirecteeName(ConstructorReferenceBuilder redirectionTarget) {
    String targetName = redirectionTarget.fullNameForErrors;
    if (targetName == "") {
      return redirectionTarget.target.parent.fullNameForErrors;
    } else {
      return targetName;
    }
  }

  void checkRedirectingFactory(KernelRedirectingFactoryBuilder factory,
      TypeEnvironment typeEnvironment) {
    // The factory type cannot contain any type parameters other than those of
    // its enclosing class, because constructors cannot specify type parameters
    // of their own.
    FunctionType factoryType =
        factory.procedure.function.functionType.withoutTypeParameters;
    FunctionType redirecteeType =
        computeRedirecteeType(factory.redirectionTarget, typeEnvironment);

    // TODO(hillerstrom): It would be preferable to know whether a failure
    // happened during [_computeRedirecteeType].
    if (redirecteeType == null) return;

    // Check whether [redirecteeType] <: [factoryType]. In the following let
    //     [factoryType    = (S_1, ..., S_i, {S_(i+1), ..., S_n}) -> S']
    //     [redirecteeType = (T_1, ..., T_j, {T_(j+1), ..., T_m}) -> T'].

    // Ensure that any extra parameters that [redirecteeType] might have are
    // optional.
    if (redirecteeType.requiredParameterCount >
        factoryType.requiredParameterCount) {
      addProblem(
          templateRedirectingFactoryProvidesTooFewRequiredParameters
              .withArguments(
                  factory.fullNameForErrors,
                  factoryType.requiredParameterCount,
                  computeRedirecteeName(factory.redirectionTarget),
                  redirecteeType.requiredParameterCount),
          factory.charOffset,
          noLength);
      return;
    }
    if (redirecteeType.positionalParameters.length <
        factoryType.positionalParameters.length) {
      String targetName = computeRedirecteeName(factory.redirectionTarget);
      addProblem(
          templateFactoryRedirecteeHasTooFewPositionalParameters.withArguments(
              targetName, redirecteeType.positionalParameters.length),
          factory.redirectionTarget.charOffset,
          noLength);
      return;
    }

    // For each 0 < k < i check S_k <: T_k.
    for (int i = 0; i < factoryType.positionalParameters.length; ++i) {
      var factoryParameterType = factoryType.positionalParameters[i];
      var redirecteeParameterType = redirecteeType.positionalParameters[i];
      if (!typeEnvironment.isSubtypeOf(
          factoryParameterType, redirecteeParameterType)) {
        final factoryParameter =
            factory.target.function.positionalParameters[i];
        addProblem(
            templateRedirectingFactoryInvalidPositionalParameterType
                .withArguments(factoryParameter.name, factoryParameterType,
                    redirecteeParameterType),
            factoryParameter.fileOffset,
            factoryParameter.name.length);
        return;
      }
    }

    // For each i < k < n check that the named parameter S_k has a corresponding
    // named parameter T_l in [redirecteeType] for some j < l < m.
    int factoryTypeNameIndex = 0; // k.
    int redirecteeTypeNameIndex = 0; // l.

    // The following code makes use of the invariant that [namedParameters] are
    // already sorted (i.e. it's a monotonic sequence) to determine in a linear
    // pass whether [factory.namedParameters] is a subset of
    // [redirectee.namedParameters]. In the comments below the symbol <= stands
    // for the usual lexicographic relation on strings.
    while (factoryTypeNameIndex < factoryType.namedParameters.length) {
      // If we have gone beyond the bound of redirectee's named parameters, then
      // signal a missing named parameter error.
      if (redirecteeTypeNameIndex == redirecteeType.namedParameters.length) {
        reportRedirectingFactoryMissingNamedParameter(
            factory, factoryType.namedParameters[factoryTypeNameIndex]);
        break;
      }

      int result = redirecteeType.namedParameters[redirecteeTypeNameIndex].name
          .compareTo(factoryType.namedParameters[factoryTypeNameIndex].name);
      if (result < 0) {
        // T_l.name <= S_k.name.
        redirecteeTypeNameIndex++;
      } else if (result == 0) {
        // S_k.name <= T_l.name.
        NamedType factoryParameterType =
            factoryType.namedParameters[factoryTypeNameIndex];
        NamedType redirecteeParameterType =
            redirecteeType.namedParameters[redirecteeTypeNameIndex];
        // Check S_k <: T_l.
        if (!typeEnvironment.isSubtypeOf(
            factoryParameterType.type, redirecteeParameterType.type)) {
          var factoryFormal =
              factory.target.function.namedParameters[redirecteeTypeNameIndex];
          addProblem(
              templateRedirectingFactoryInvalidNamedParameterType.withArguments(
                  factoryParameterType.name,
                  factoryParameterType.type,
                  redirecteeParameterType.type),
              factoryFormal.fileOffset,
              factoryFormal.name.length);
          return;
        }
        redirecteeTypeNameIndex++;
        factoryTypeNameIndex++;
      } else {
        // S_k.name <= T_l.name. By appealing to the monotinicity of
        // [namedParameters] and the transivity of <= it follows that for any
        // l', such that l < l', it must be the case that S_k <= T_l'. Thus the
        // named parameter is missing from the redirectee's parameter list.
        reportRedirectingFactoryMissingNamedParameter(
            factory, factoryType.namedParameters[factoryTypeNameIndex]);

        // Continue with the next factory named parameter.
        factoryTypeNameIndex++;
      }
    }

    // Report any unprocessed factory named parameters as missing.
    if (factoryTypeNameIndex < factoryType.namedParameters.length) {
      for (int i = factoryTypeNameIndex;
          i < factoryType.namedParameters.length;
          i++) {
        reportRedirectingFactoryMissingNamedParameter(
            factory, factoryType.namedParameters[factoryTypeNameIndex]);
      }
    }

    // Check that T' <: S'.
    if (!typeEnvironment.isSubtypeOf(
        redirecteeType.returnType, factoryType.returnType)) {
      String targetName = computeRedirecteeName(factory.redirectionTarget);
      addProblem(
          templateFactoryRedirecteeInvalidReturnType.withArguments(
              redirecteeType.returnType, targetName, factoryType.returnType),
          factory.redirectionTarget.charOffset,
          noLength);
      return;
    }
  }

  void reportRedirectingFactoryMissingNamedParameter(
      KernelRedirectingFactoryBuilder factory, NamedType missingParameter) {
    addProblem(
        templateRedirectingFactoryMissingNamedParameter.withArguments(
            computeRedirecteeName(factory.redirectionTarget),
            missingParameter.name),
        factory.redirectionTarget.charOffset,
        noLength);
  }

  void checkRedirectingFactories(TypeEnvironment typeEnvironment) {
    Map<String, MemberBuilder> constructors = this.constructors.local;
    Iterable<String> names = constructors.keys;
    for (String name in names) {
      Declaration constructor = constructors[name];
      if (constructor is KernelRedirectingFactoryBuilder) {
        checkRedirectingFactory(constructor, typeEnvironment);
      }
    }
  }
}
