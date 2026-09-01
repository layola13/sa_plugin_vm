const std = @import("std");

pub const Token = struct {
    tag: Tag,
    loc: Loc,

    pub const Loc = struct {
        start: usize,
        end: usize,
    };

    pub const Tag = enum {
        eof,
        invalid,
        identifier,

        // Literals
        int_literal,
        float_literal,
        string_literal,

        // Keywords
        keyword_struct,
        keyword_union,
        keyword_enum,
        keyword_trait,
        keyword_overload,
        keyword_dyn,
        keyword_impl,
        keyword_mod,
        keyword_using,
        keyword_pub,
        keyword_extern,
        keyword_async,
        keyword_await,
        keyword_unsafe,
        keyword_as,
        keyword_fn,
        keyword_if,
        keyword_else,
        keyword_match,
        keyword_switch,
        keyword_return,
        keyword_for,
        keyword_while,
        keyword_break,
        keyword_continue,
        keyword_in,
        keyword_let,
        keyword_const,
        keyword_var,
        keyword_inline,
        keyword_macro,
        keyword_mut,
        keyword_type,

        // Symbols
        plus, // +
        plus_equal, // +=
        pipe_equal, // |=
        ampersand_equal, // &=
        minus, // -
        asterisk, // *
        slash, // /
        percent, // %
        equal, // =
        equal_equal, // ==
        bang_equal, // !=
        less_equal, // <=
        greater_equal, // >=
        ampersand, // &
        amp_amp, // &&
        caret, // ^
        bang, // !
        pipe, // |
        pipe_pipe, // ||
        less_less, // <<
        greater_greater, // >>
        spaceship, // <=>
        dot, // .
        comma, // ,
        semicolon, // ;
        colon, // :
        double_colon, // ::
        l_paren, // (
        r_paren, // )
        l_brace, // {
        r_brace, // }
        l_bracket, // [
        r_bracket, // ]
        less_than, // <
        greater_than, // >
        arrow, // ->
        fat_arrow, // =>
        range, // ..
        question_mark, // ?
        at, // @
    };
};

pub const Lexer = struct {
    buffer: []const u8,
    index: usize,

    pub fn init(buffer: []const u8) Lexer {
        return .{
            .buffer = buffer,
            .index = 0,
        };
    }

    pub fn next(self: *Lexer) Token {
        self.skipWhitespace();

        if (self.index >= self.buffer.len) {
            return Token{
                .tag = .eof,
                .loc = .{ .start = self.index, .end = self.index },
            };
        }

        const start = self.index;
        const c = self.buffer[self.index];
        self.index += 1;

        switch (c) {
            '@' => return Token{ .tag = .at, .loc = .{ .start = start, .end = self.index } },
            '?' => return Token{ .tag = .question_mark, .loc = .{ .start = start, .end = self.index } },
            '+' => {
                if (self.index < self.buffer.len and self.buffer[self.index] == '=') {
                    self.index += 1;
                    return Token{ .tag = .plus_equal, .loc = .{ .start = start, .end = self.index } };
                }
                return Token{ .tag = .plus, .loc = .{ .start = start, .end = self.index } };
            },
            '-' => {
                if (self.index < self.buffer.len and self.buffer[self.index] == '>') {
                    self.index += 1;
                    return Token{ .tag = .arrow, .loc = .{ .start = start, .end = self.index } };
                }
                return Token{ .tag = .minus, .loc = .{ .start = start, .end = self.index } };
            },
            '*' => return Token{ .tag = .asterisk, .loc = .{ .start = start, .end = self.index } },
            '/' => {
                if (self.index < self.buffer.len and self.buffer[self.index] == '/') {
                    // Line comment, skip till newline
                    self.index += 1;
                    while (self.index < self.buffer.len and self.buffer[self.index] != '\n') : (self.index += 1) {}
                    return self.next();
                }
                return Token{ .tag = .slash, .loc = .{ .start = start, .end = self.index } };
            },
            '%' => return Token{ .tag = .percent, .loc = .{ .start = start, .end = self.index } },
            '=' => {
                if (self.index < self.buffer.len and self.buffer[self.index] == '>') {
                    self.index += 1;
                    return Token{ .tag = .fat_arrow, .loc = .{ .start = start, .end = self.index } };
                }
                if (self.index < self.buffer.len and self.buffer[self.index] == '=') {
                    self.index += 1;
                    return Token{ .tag = .equal_equal, .loc = .{ .start = start, .end = self.index } };
                }
                return Token{ .tag = .equal, .loc = .{ .start = start, .end = self.index } };
            },
            '&' => {
                if (self.index < self.buffer.len and self.buffer[self.index] == '=') {
                    self.index += 1;
                    return Token{ .tag = .ampersand_equal, .loc = .{ .start = start, .end = self.index } };
                }
                if (self.index < self.buffer.len and self.buffer[self.index] == '&') {
                    self.index += 1;
                    return Token{ .tag = .amp_amp, .loc = .{ .start = start, .end = self.index } };
                }
                return Token{ .tag = .ampersand, .loc = .{ .start = start, .end = self.index } };
            },
            '^' => return Token{ .tag = .caret, .loc = .{ .start = start, .end = self.index } },
            '|' => {
                if (self.index < self.buffer.len and self.buffer[self.index] == '|') {
                    self.index += 1;
                    return Token{ .tag = .pipe_pipe, .loc = .{ .start = start, .end = self.index } };
                }
                if (self.index < self.buffer.len and self.buffer[self.index] == '=') {
                    self.index += 1;
                    return Token{ .tag = .pipe_equal, .loc = .{ .start = start, .end = self.index } };
                }
                return Token{ .tag = .pipe, .loc = .{ .start = start, .end = self.index } };
            },
            '!' => {
                if (self.index < self.buffer.len and self.buffer[self.index] == '=') {
                    self.index += 1;
                    return Token{ .tag = .bang_equal, .loc = .{ .start = start, .end = self.index } };
                }
                return Token{ .tag = .bang, .loc = .{ .start = start, .end = self.index } };
            },
            '.' => {
                if (self.index < self.buffer.len and self.buffer[self.index] == '.') {
                    self.index += 1;
                    return Token{ .tag = .range, .loc = .{ .start = start, .end = self.index } };
                }
                return Token{ .tag = .dot, .loc = .{ .start = start, .end = self.index } };
            },
            ',' => return Token{ .tag = .comma, .loc = .{ .start = start, .end = self.index } },
            ';' => return Token{ .tag = .semicolon, .loc = .{ .start = start, .end = self.index } },
            ':' => {
                if (self.index < self.buffer.len and self.buffer[self.index] == ':') {
                    self.index += 1;
                    return Token{ .tag = .double_colon, .loc = .{ .start = start, .end = self.index } };
                }
                return Token{ .tag = .colon, .loc = .{ .start = start, .end = self.index } };
            },
            '(' => return Token{ .tag = .l_paren, .loc = .{ .start = start, .end = self.index } },
            ')' => return Token{ .tag = .r_paren, .loc = .{ .start = start, .end = self.index } },
            '{' => return Token{ .tag = .l_brace, .loc = .{ .start = start, .end = self.index } },
            '}' => return Token{ .tag = .r_brace, .loc = .{ .start = start, .end = self.index } },
            '[' => return Token{ .tag = .l_bracket, .loc = .{ .start = start, .end = self.index } },
            ']' => return Token{ .tag = .r_bracket, .loc = .{ .start = start, .end = self.index } },
            '<' => {
                if (self.index < self.buffer.len and self.buffer[self.index] == '<') {
                    self.index += 1;
                    return Token{ .tag = .less_less, .loc = .{ .start = start, .end = self.index } };
                }
                if (self.index + 1 < self.buffer.len and self.buffer[self.index] == '=' and self.buffer[self.index + 1] == '>') {
                    self.index += 2;
                    return Token{ .tag = .spaceship, .loc = .{ .start = start, .end = self.index } };
                }
                if (self.index < self.buffer.len and self.buffer[self.index] == '=') {
                    self.index += 1;
                    return Token{ .tag = .less_equal, .loc = .{ .start = start, .end = self.index } };
                }
                return Token{ .tag = .less_than, .loc = .{ .start = start, .end = self.index } };
            },
            '>' => {
                if (self.index < self.buffer.len and self.buffer[self.index] == '>') {
                    self.index += 1;
                    return Token{ .tag = .greater_greater, .loc = .{ .start = start, .end = self.index } };
                }
                if (self.index < self.buffer.len and self.buffer[self.index] == '=') {
                    self.index += 1;
                    return Token{ .tag = .greater_equal, .loc = .{ .start = start, .end = self.index } };
                }
                return Token{ .tag = .greater_than, .loc = .{ .start = start, .end = self.index } };
            },
            '"' => {
                while (self.index < self.buffer.len and self.buffer[self.index] != '"') : (self.index += 1) {
                    if (self.buffer[self.index] == '\\') {
                        self.index += 1;
                    }
                }
                if (self.index < self.buffer.len) {
                    self.index += 1; // skip closing quote
                    return Token{ .tag = .string_literal, .loc = .{ .start = start, .end = self.index } };
                }
                return Token{ .tag = .invalid, .loc = .{ .start = start, .end = self.index } };
            },
            'a'...'z', 'A'...'Z', '_' => {
                while (self.index < self.buffer.len) : (self.index += 1) {
                    const next_c = self.buffer[self.index];
                    if (!std.ascii.isAlphanumeric(next_c) and next_c != '_') break;
                }
                const ident_str = self.buffer[start..self.index];
                const tag = checkKeyword(ident_str);
                return Token{ .tag = tag, .loc = .{ .start = start, .end = self.index } };
            },
            '0'...'9' => {
                if (c == '0' and self.index < self.buffer.len and (self.buffer[self.index] == 'x' or self.buffer[self.index] == 'X')) {
                    self.index += 1;
                    while (self.index < self.buffer.len and std.ascii.isHex(self.buffer[self.index])) : (self.index += 1) {}
                    while (self.index < self.buffer.len and std.ascii.isAlphabetic(self.buffer[self.index])) : (self.index += 1) {}
                    while (self.index < self.buffer.len and std.ascii.isDigit(self.buffer[self.index])) : (self.index += 1) {}
                    return Token{ .tag = .int_literal, .loc = .{ .start = start, .end = self.index } };
                }
                var is_float = false;
                while (self.index < self.buffer.len) : (self.index += 1) {
                    const next_c = self.buffer[self.index];
                    if (next_c == '.') {
                        // Check if it is a range operator '..' or a float dot '.'
                        if (self.index + 1 < self.buffer.len and self.buffer[self.index + 1] == '.') {
                            break; // Range operator, stop parsing number
                        }
                        if (self.index + 1 >= self.buffer.len or !std.ascii.isDigit(self.buffer[self.index + 1])) {
                            break;
                        }
                        is_float = true;
                    } else if (!std.ascii.isDigit(next_c)) {
                        break;
                    }
                }
                if (!is_float) {
                    while (self.index < self.buffer.len and std.ascii.isAlphanumeric(self.buffer[self.index])) : (self.index += 1) {}
                }
                const tag: Token.Tag = if (is_float) .float_literal else .int_literal;
                return Token{ .tag = tag, .loc = .{ .start = start, .end = self.index } };
            },
            else => return Token{ .tag = .invalid, .loc = .{ .start = start, .end = self.index } },
        }
    }

    fn skipWhitespace(self: *Lexer) void {
        while (self.index < self.buffer.len) : (self.index += 1) {
            const c = self.buffer[self.index];
            if (c != ' ' and c != '\t' and c != '\n' and c != '\r') break;
        }
    }

    fn checkKeyword(str: []const u8) Token.Tag {
        if (std.mem.eql(u8, str, "struct")) return .keyword_struct;
        if (std.mem.eql(u8, str, "union")) return .keyword_union;
        if (std.mem.eql(u8, str, "enum")) return .keyword_enum;
        if (std.mem.eql(u8, str, "trait")) return .keyword_trait;
        if (std.mem.eql(u8, str, "overload")) return .keyword_overload;
        if (std.mem.eql(u8, str, "dyn")) return .keyword_dyn;
        if (std.mem.eql(u8, str, "impl")) return .keyword_impl;
        if (std.mem.eql(u8, str, "mod")) return .keyword_mod;
        if (std.mem.eql(u8, str, "using")) return .keyword_using;
        if (std.mem.eql(u8, str, "pub")) return .keyword_pub;
        if (std.mem.eql(u8, str, "extern")) return .keyword_extern;
        if (std.mem.eql(u8, str, "async")) return .keyword_async;
        if (std.mem.eql(u8, str, "await")) return .keyword_await;
        if (std.mem.eql(u8, str, "unsafe")) return .keyword_unsafe;
        if (std.mem.eql(u8, str, "as")) return .keyword_as;
        if (std.mem.eql(u8, str, "fn")) return .keyword_fn;
        if (std.mem.eql(u8, str, "if")) return .keyword_if;
        if (std.mem.eql(u8, str, "else")) return .keyword_else;
        if (std.mem.eql(u8, str, "match")) return .keyword_match;
        if (std.mem.eql(u8, str, "switch")) return .keyword_switch;
        if (std.mem.eql(u8, str, "return")) return .keyword_return;
        if (std.mem.eql(u8, str, "for")) return .keyword_for;
        if (std.mem.eql(u8, str, "while")) return .keyword_while;
        if (std.mem.eql(u8, str, "break")) return .keyword_break;
        if (std.mem.eql(u8, str, "continue")) return .keyword_continue;
        if (std.mem.eql(u8, str, "in")) return .keyword_in;
        if (std.mem.eql(u8, str, "let")) return .keyword_let;
        if (std.mem.eql(u8, str, "const")) return .keyword_const;
        if (std.mem.eql(u8, str, "var")) return .keyword_var;
        if (std.mem.eql(u8, str, "inline")) return .keyword_inline;
        if (std.mem.eql(u8, str, "macro")) return .keyword_macro;
        if (std.mem.eql(u8, str, "mut")) return .keyword_mut;
        if (std.mem.eql(u8, str, "type")) return .keyword_type;
        return .identifier;
    }
};

test "basic lexing" {
    const source = "struct Option<T> { has_value: bool, value: T }";
    var l = Lexer.init(source);

    try std.testing.expectEqual(Token.Tag.keyword_struct, l.next().tag);
    try std.testing.expectEqual(Token.Tag.identifier, l.next().tag);
    try std.testing.expectEqual(Token.Tag.less_than, l.next().tag);
    try std.testing.expectEqual(Token.Tag.identifier, l.next().tag);
    try std.testing.expectEqual(Token.Tag.greater_than, l.next().tag);
    try std.testing.expectEqual(Token.Tag.l_brace, l.next().tag);
    try std.testing.expectEqual(Token.Tag.identifier, l.next().tag);
    try std.testing.expectEqual(Token.Tag.colon, l.next().tag);
    try std.testing.expectEqual(Token.Tag.identifier, l.next().tag);
    try std.testing.expectEqual(Token.Tag.comma, l.next().tag);
    try std.testing.expectEqual(Token.Tag.identifier, l.next().tag);
    try std.testing.expectEqual(Token.Tag.colon, l.next().tag);
    try std.testing.expectEqual(Token.Tag.identifier, l.next().tag);
    try std.testing.expectEqual(Token.Tag.r_brace, l.next().tag);
    try std.testing.expectEqual(Token.Tag.eof, l.next().tag);
}
