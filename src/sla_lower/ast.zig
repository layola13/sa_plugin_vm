const std = @import("std");

pub const Node = union(enum) {
    program: Program,

    // Declarations
    struct_decl: StructDecl,
    enum_decl: EnumDecl,
    trait_decl: TraitDecl,
    impl_decl: ImplDecl,
    type_alias_decl: TypeAliasDecl,
    overload_decl: OverloadDecl,
    func_decl: FuncDecl,
    macro_decl: MacroDecl,
    import_decl: ImportDecl,
    using_decl: UsingDecl,
    test_decl: TestDecl,

    // Statements
    let_stmt: LetStmt,
    let_else_stmt: LetElseStmt,
    let_destructure_stmt: LetDestructureStmt,
    const_stmt: ConstStmt,
    var_stmt: VarStmt,
    assign_stmt: AssignStmt,
    block_stmt: BlockStmt,
    expr_stmt: *Node,
    return_stmt: ReturnStmt,
    for_stmt: ForStmt,
    while_stmt: WhileStmt,
    break_stmt: BreakStmt,
    continue_stmt: ContinueStmt,
    release_stmt: ReleaseStmt,

    // Expressions
    literal: Literal,
    identifier: []const u8,
    generic_func_ref: GenericFuncRef,
    if_expr: IfExpr,
    switch_expr: SwitchExpr,
    match_expr: MatchExpr,
    unsafe_expr: UnsafeExpr,
    await_expr: AwaitExpr,
    inline_asm_expr: InlineAsmExpr,
    binary_expr: BinaryExpr,
    call_expr: CallExpr,
    closure_literal: ClosureLiteral,
    borrow_expr: BorrowExpr,
    move_expr: MoveExpr,
    deref_expr: DerefExpr,
    cast_expr: CastExpr,
    field_expr: FieldExpr,
    struct_literal: StructLiteral,
    enum_literal: EnumLiteral,
    tuple_literal: TupleLiteral,
    array_literal: ArrayLiteral,
    repeat_array_literal: RepeatArrayLiteral,
    index_expr: IndexExpr,
    slice_expr: SliceExpr,
    try_expr: TryExpr,
};

pub const Program = struct {
    decls: []const *Node,
};

pub const StructDecl = struct {
    name: []const u8,
    derives: []const []const u8 = &.{},
    generics: []const []const u8,
    fields: []const Field,
    is_union: bool = false,
    is_opaque: bool = false,
};

pub const EnumDecl = struct {
    name: []const u8,
    generics: []const []const u8,
    variants: []const EnumVariant,
};

pub const EnumVariant = struct {
    name: []const u8,
    fields: []const Field,
};

pub const ImplDecl = struct {
    trait_name: ?[]const u8 = null,
    target_ty: *Type,
    methods: []const *Node,
};

pub const TypeAliasDecl = struct {
    name: []const u8,
    components: []const TypeAliasComponent,
};

pub const TypeAliasComponent = union(enum) {
    ty: *Type,
    inline_struct: []const Field,
};

pub const OverloadDecl = struct {
    target_ty: *Type,
    methods: []const *Node,
};

pub const TraitMethod = struct {
    name: []const u8,
    params: []const Param,
    ret_ty: *Type,
};

pub const TraitDecl = struct {
    name: []const u8,
    supertraits: []const []const u8 = &.{},
    methods: []const TraitMethod,
};

pub const Field = struct {
    name: []const u8,
    ty: *Type,
};

pub const FuncDecl = struct {
    name: []const u8,
    is_pub: bool = false,
    is_extern: bool = false,
    abi: ?[]const u8 = null,
    no_mangle: bool = false,
    is_decl_only: bool = false,
    generics: []const []const u8,
    params: []const Param,
    ret_ty: *Type,
    body: []const *Node,
    is_inline: bool,
    is_async: bool = false,
    operator: ?BinaryOp = null,
};

pub const Param = struct {
    name: []const u8,
    ty: *Type,
    is_borrow: bool = false,
    is_move: bool = false,
};

pub const MacroDecl = struct {
    name: []const u8,
    params: []const []const u8,
    body: []const *Node,
};

pub const ImportDecl = struct {
    path: []const u8,
};

pub const UsingDecl = struct {
    path: []const u8,
};

pub const TestDecl = struct {
    name: []const u8,
    is_ignored: bool,
    should_panic: bool,
    body: []const *Node,
};

pub const LetStmt = struct {
    name: []const u8,
    ty: ?*Type,
    value: *Node,
};

pub const LetElseStmt = struct {
    pattern: EnumPattern,
    value: *Node,
    else_block: []const *Node,
};

pub const LetDestructureStmt = struct {
    names: []const []const u8,
    value: *Node,
    rest_name: ?[]const u8 = null,
    rest_alias: ?[]const u8 = null,
    is_slice: bool = false,
};

pub const ConstStmt = struct {
    name: []const u8,
    ty: ?*Type,
    value: *Node,
};

pub const VarStmt = struct {
    name: []const u8,
    ty: *Type,
};

pub const AssignStmt = struct {
    target: *Node,
    value: *Node,
};

pub const BlockStmt = struct {
    body: []const *Node,
};

pub const ReturnStmt = struct {
    value: ?*Node,
};

pub const ForStmt = struct {
    var_name: []const u8,
    start: *Node,
    end: ?*Node,
    body: []const *Node,
};

pub const WhileStmt = struct {
    cond: *Node,
    let_pattern: ?EnumPattern = null,
    body: []const *Node,
};

pub const BreakStmt = struct {};

pub const ContinueStmt = struct {};

pub const ReleaseStmt = struct {
    var_name: []const u8,
};

pub const Literal = union(enum) {
    int_val: i64,
    float_val: f64,
    bool_val: bool,
    string_val: []const u8,
};

pub const IfExpr = struct {
    cond: *Node,
    let_chain: ?[]const IfLetCond = null,
    then_block: []const *Node,
    else_block: ?[]const *Node,
};

pub const IfLetCond = struct {
    pattern: EnumPattern,
    value: *Node,
};

pub const Case = struct {
    pattern: *Node, // Literal or Identifier (for default pattern, e.g. "default")
    body: []const *Node,
};

pub const SwitchExpr = struct {
    val: *Node,
    cases: []const Case,
};

pub const MatchExpr = struct {
    val: *Node,
    cases: []const MatchCase,
};

pub const UnsafeExpr = struct {
    body: []const *Node,
};

pub const MatchCase = struct {
    pattern: EnumPattern,
    guard: ?*Node = null,
    body: []const *Node,
};

pub const AwaitExpr = struct {
    expr: *Node,
};

pub const InlineAsmOperand = struct {
    constraint: []const u8,
    var_name: []const u8,
};

pub const InlineAsmExpr = struct {
    template: []const u8,
    operands: []const InlineAsmOperand,
};

pub const ClosureLiteral = struct {
    params: []const Param,
    body: *Node,
};

pub const EnumPattern = struct {
    enum_name: []const u8,
    variant_name: []const u8,
    bindings: []const []const u8,
};

pub const BinaryOp = enum {
    add,
    sub,
    mul,
    div,
    mod,
    bit_and,
    bit_or,
    bit_xor,
    shl,
    shr,
    eq,
    ne,
    lt,
    le,
    gt,
    ge,
    spaceship,
    logical_and,
    logical_or,
};

pub const BinaryExpr = struct {
    op: BinaryOp,
    left: *Node,
    right: *Node,
};

pub const CallExpr = struct {
    func_name: []const u8,
    associated_target: ?[]const u8 = null,
    generics: []const *Type,
    args: []const *Node,
};

pub const GenericFuncRef = struct {
    func_name: []const u8,
    generics: []const *Type,
};

pub const BorrowExpr = struct {
    expr: *Node,
};

pub const MoveExpr = struct {
    expr: *Node,
};

pub const DerefExpr = struct {
    expr: *Node,
};

pub const CastExpr = struct {
    expr: *Node,
    ty: *Type,
};

pub const FieldExpr = struct {
    expr: *Node,
    field_name: []const u8,
};

pub const StructLiteralField = struct {
    name: []const u8,
    value: *Node,
};

pub const StructLiteral = struct {
    ty: *Type,
    fields: []const StructLiteralField,
    update_expr: ?*Node = null,
};

pub const EnumLiteralField = struct {
    name: []const u8,
    value: *Node,
};

pub const EnumLiteral = struct {
    enum_name: []const u8,
    variant_name: []const u8,
    fields: []const EnumLiteralField,
};

pub const TupleLiteral = struct {
    elements: []const *Node,
};

pub const ArrayLiteral = struct {
    elements: []const *Node,
};

pub const RepeatArrayLiteral = struct {
    value: *Node,
    len: usize,
};

pub const IndexExpr = struct {
    target: *Node,
    index: *Node,
};

pub const SliceExpr = struct {
    target: *Node,
    start: *Node,
    end: *Node,
};

pub const TryExpr = struct {
    expr: *Node,
};

// Type System representation
pub const Type = union(enum) {
    infer,
    primitive: Primitive,
    pointer: *Type,
    borrow: *Type,
    array: ArrayType,
    tuple: TupleType,
    future: *Type,
    closure: ClosureType,
    fn_ptr: FnPtrType,
    user_defined: UserDefined,
};

pub const Primitive = enum {
    // Integer primitives
    i8,
    i16,
    i32,
    i64,
    isize,
    u8,
    u16,
    u32,
    u64,
    usize,
    // Floating-point primitives
    f32,
    f64,
    // Legacy aliases kept during migration.
    integer,
    float,
    boolean,
    raw_ptr,
    void_type,
};

pub const UserDefined = struct {
    name: []const u8,
    generics: []const *Type,
};

pub const ArrayType = struct {
    elem: *Type,
    len: usize,
};

pub const TupleType = struct {
    elems: []const *Type,
};

pub const ClosureType = struct {
    params: []const *Type,
    ret: *Type,
};

pub const FnPtrType = struct {
    abi: ?[]const u8 = null,
    params: []const *Type,
    ret: *Type,
};
