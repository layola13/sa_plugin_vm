const std = @import("std");

pub const schema_json =
    \\
    \\{
    \\  "$schema": "https://json-schema.org/draft/2020-12/schema",
    \\  "$id": "https://sa.dev/sla/stability-metadata.schema.json",
    \\  "title": "SLA downstream stability metadata",
    \\  "type": "object",
    \\  "required": ["schema_version", "labels", "artifacts"],
    \\  "properties": {
    \\    "schema_version": { "const": 1 },
    \\    "project": { "type": "string", "minLength": 1 },
    \\    "labels": {
    \\      "type": "array",
    \\      "items": {
    \\        "type": "object",
    \\        "required": ["name", "description"],
    \\        "properties": {
    \\          "name": { "type": "string", "pattern": "^[A-Za-z0-9][A-Za-z0-9_.-]*$" },
    \\          "description": { "type": "string", "minLength": 1 }
    \\        },
    \\        "additionalProperties": false
    \\      },
    \\      "uniqueItems": true
    \\    },
    \\    "artifacts": {
    \\      "type": "array",
    \\      "items": {
    \\        "type": "object",
    \\        "required": ["path", "labels"],
    \\        "properties": {
    \\          "path": { "type": "string", "minLength": 1 },
    \\          "labels": { "type": "array", "items": { "type": "string" } },
    \\          "evidence": {
    \\            "type": "array",
    \\            "items": {
    \\              "type": "object",
    \\              "required": ["kind", "status"],
    \\              "properties": {
    \\                "kind": { "type": "string", "minLength": 1 },
    \\                "status": { "enum": ["pass", "fail", "unknown"] },
    \\                "command": { "type": "string" },
    \\                "note": { "type": "string" }
    \\              },
    \\              "additionalProperties": false
    \\            }
    \\          }
    \\        },
    \\        "additionalProperties": false
    \\      }
    \\    }
    \\  },
    \\  "additionalProperties": false
    \\}
    \\
;

pub const example_manifest_json =
    \\
    \\{
    \\  "schema_version": 1,
    \\  "project": "downstream-project",
    \\  "labels": [
    \\    { "name": "stable-demo", "description": "User-facing demo with repeatable verification evidence." },
    \\    { "name": "verified-sa-backend", "description": "SA-text backend verification passed for this artifact." },
    \\    { "name": "verified-sab-backend", "description": "Direct SAB verification passed for this artifact." },
    \\    { "name": "experimental-parallel", "description": "Parallel behavior is experimental and not a parity claim." },
    \\    { "name": "shape-only-reflect", "description": "Reflection covers shape metadata only." }
    \\  ],
    \\  "artifacts": [
    \\    {
    \\      "path": "lib/parallel.sla",
    \\      "labels": ["verified-sab-backend", "experimental-parallel"],
    \\      "evidence": [
    \\        { "kind": "command", "status": "pass", "command": "SA_PLUGIN_DEV=1 sa sla test lib/parallel.sla --test-backend sab" }
    \\      ]
    \\    }
    \\  ]
    \\}
    \\
;

pub const ValidationReport = struct {
    allocator: std.mem.Allocator,
    valid: bool = true,
    label_count: usize = 0,
    artifact_count: usize = 0,
    evidence_count: usize = 0,
    errors: std.ArrayList([]u8),

    pub fn init(allocator: std.mem.Allocator) ValidationReport {
        return .{
            .allocator = allocator,
            .errors = std.ArrayList([]u8).init(allocator),
        };
    }

    pub fn deinit(self: *ValidationReport) void {
        for (self.errors.items) |message| self.allocator.free(message);
        self.errors.deinit();
    }

    fn addError(self: *ValidationReport, comptime fmt: []const u8, args: anytype) !void {
        self.valid = false;
        try self.errors.append(try std.fmt.allocPrint(self.allocator, fmt, args));
    }
};

pub fn validateManifestText(allocator: std.mem.Allocator, text: []const u8) !ValidationReport {
    var report = ValidationReport.init(allocator);
    errdefer report.deinit();

    var parsed = std.json.parseFromSlice(std.json.Value, allocator, text, .{}) catch |err| {
        try report.addError("invalid JSON: {s}", .{@errorName(err)});
        return report;
    };
    defer parsed.deinit();

    try validateRoot(&report, parsed.value);
    return report;
}

fn validateRoot(report: *ValidationReport, value: std.json.Value) !void {
    if (value != .object) {
        try report.addError("root must be an object", .{});
        return;
    }
    const object = value.object;

    if (object.get("schema_version")) |schema_version| {
        if (schema_version != .integer or schema_version.integer != 1) {
            try report.addError("schema_version must be integer 1", .{});
        }
    } else {
        try report.addError("missing required field: schema_version", .{});
    }

    if (object.get("project")) |project| {
        if (project != .string or project.string.len == 0) {
            try report.addError("project must be a non-empty string when present", .{});
        }
    }

    var declared_labels = std.StringHashMap(void).init(report.allocator);
    defer declared_labels.deinit();

    if (object.get("labels")) |labels| {
        try validateLabels(report, labels, &declared_labels);
    } else {
        try report.addError("missing required field: labels", .{});
    }

    if (object.get("artifacts")) |artifacts| {
        try validateArtifacts(report, artifacts, &declared_labels);
    } else {
        try report.addError("missing required field: artifacts", .{});
    }
}

fn validateLabels(report: *ValidationReport, value: std.json.Value, declared_labels: *std.StringHashMap(void)) !void {
    if (value != .array) {
        try report.addError("labels must be an array", .{});
        return;
    }
    for (value.array.items, 0..) |entry, idx| {
        if (entry != .object) {
            try report.addError("labels[{d}] must be an object", .{idx});
            continue;
        }
        const object = entry.object;
        const name_value = object.get("name") orelse {
            try report.addError("labels[{d}] missing name", .{idx});
            continue;
        };
        if (name_value != .string or !isValidLabelName(name_value.string)) {
            try report.addError("labels[{d}].name must match [A-Za-z0-9][A-Za-z0-9_.-]*", .{idx});
            continue;
        }
        const description_value = object.get("description") orelse {
            try report.addError("labels[{d}] missing description", .{idx});
            continue;
        };
        if (description_value != .string or description_value.string.len == 0) {
            try report.addError("labels[{d}].description must be a non-empty string", .{idx});
        }
        if (declared_labels.contains(name_value.string)) {
            try report.addError("duplicate label: {s}", .{name_value.string});
        } else {
            try declared_labels.put(name_value.string, {});
            report.label_count += 1;
        }
    }
}

fn validateArtifacts(report: *ValidationReport, value: std.json.Value, declared_labels: *const std.StringHashMap(void)) !void {
    if (value != .array) {
        try report.addError("artifacts must be an array", .{});
        return;
    }
    for (value.array.items, 0..) |entry, idx| {
        if (entry != .object) {
            try report.addError("artifacts[{d}] must be an object", .{idx});
            continue;
        }
        const object = entry.object;
        const path_value = object.get("path") orelse {
            try report.addError("artifacts[{d}] missing path", .{idx});
            continue;
        };
        if (path_value != .string or !isValidArtifactPath(path_value.string)) {
            try report.addError("artifacts[{d}].path must be a non-empty relative path without '..' segments", .{idx});
        }
        if (object.get("labels")) |labels| {
            try validateArtifactLabels(report, labels, idx, declared_labels);
        } else {
            try report.addError("artifacts[{d}] missing labels", .{idx});
        }
        if (object.get("evidence")) |evidence| {
            try validateEvidence(report, evidence, idx);
        }
        report.artifact_count += 1;
    }
}

fn validateArtifactLabels(report: *ValidationReport, value: std.json.Value, artifact_idx: usize, declared_labels: *const std.StringHashMap(void)) !void {
    if (value != .array) {
        try report.addError("artifacts[{d}].labels must be an array", .{artifact_idx});
        return;
    }
    for (value.array.items, 0..) |label_value, label_idx| {
        if (label_value != .string) {
            try report.addError("artifacts[{d}].labels[{d}] must be a string", .{ artifact_idx, label_idx });
            continue;
        }
        if (!isValidLabelName(label_value.string)) {
            try report.addError("artifacts[{d}].labels[{d}] has invalid label name: {s}", .{ artifact_idx, label_idx, label_value.string });
            continue;
        }
        if (!declared_labels.contains(label_value.string)) {
            try report.addError("artifacts[{d}].labels[{d}] references undeclared label: {s}", .{ artifact_idx, label_idx, label_value.string });
        }
    }
}

fn validateEvidence(report: *ValidationReport, value: std.json.Value, artifact_idx: usize) !void {
    if (value != .array) {
        try report.addError("artifacts[{d}].evidence must be an array", .{artifact_idx});
        return;
    }
    for (value.array.items, 0..) |entry, evidence_idx| {
        if (entry != .object) {
            try report.addError("artifacts[{d}].evidence[{d}] must be an object", .{ artifact_idx, evidence_idx });
            continue;
        }
        const object = entry.object;
        const kind_value = object.get("kind") orelse {
            try report.addError("artifacts[{d}].evidence[{d}] missing kind", .{ artifact_idx, evidence_idx });
            continue;
        };
        if (kind_value != .string or kind_value.string.len == 0) {
            try report.addError("artifacts[{d}].evidence[{d}].kind must be a non-empty string", .{ artifact_idx, evidence_idx });
        }
        const status_value = object.get("status") orelse {
            try report.addError("artifacts[{d}].evidence[{d}] missing status", .{ artifact_idx, evidence_idx });
            continue;
        };
        if (status_value != .string or !isValidEvidenceStatus(status_value.string)) {
            try report.addError("artifacts[{d}].evidence[{d}].status must be pass, fail, or unknown", .{ artifact_idx, evidence_idx });
        }
        report.evidence_count += 1;
    }
}

fn isValidLabelName(name: []const u8) bool {
    if (name.len == 0) return false;
    if (!isLabelStart(name[0])) return false;
    for (name[1..]) |c| {
        if (!isLabelChar(c)) return false;
    }
    return true;
}

fn isLabelStart(c: u8) bool {
    return std.ascii.isAlphanumeric(c);
}

fn isLabelChar(c: u8) bool {
    return std.ascii.isAlphanumeric(c) or c == '_' or c == '-' or c == '.';
}

fn isValidArtifactPath(path: []const u8) bool {
    if (path.len == 0) return false;
    if (std.fs.path.isAbsolute(path)) return false;
    var parts = std.mem.splitScalar(u8, path, '/');
    while (parts.next()) |part| {
        if (std.mem.eql(u8, part, "..")) return false;
    }
    return true;
}

fn isValidEvidenceStatus(status: []const u8) bool {
    return std.mem.eql(u8, status, "pass") or
        std.mem.eql(u8, status, "fail") or
        std.mem.eql(u8, status, "unknown");
}

pub fn writeReportJson(writer: std.io.AnyWriter, report: *const ValidationReport) !void {
    try writer.writeAll("{\"status\":");
    try writeJsonString(writer, if (report.valid) "ok" else "error");
    try writer.print(",\"valid\":{},\"labels\":{d},\"artifacts\":{d},\"evidence\":{d},\"errors\":[", .{
        report.valid,
        report.label_count,
        report.artifact_count,
        report.evidence_count,
    });
    for (report.errors.items, 0..) |message, idx| {
        if (idx != 0) try writer.writeAll(",");
        try writeJsonString(writer, message);
    }
    try writer.writeAll("]}\n");
}

pub fn writeReportText(writer: std.io.AnyWriter, report: *const ValidationReport) !void {
    if (report.valid) {
        try writer.writeAll("stability metadata manifest ok\n");
    } else {
        try writer.writeAll("stability metadata manifest invalid\n");
    }
    try writer.print("labels: {d}\nartifacts: {d}\nevidence: {d}\n", .{
        report.label_count,
        report.artifact_count,
        report.evidence_count,
    });
    for (report.errors.items) |message| {
        try writer.print("error: {s}\n", .{message});
    }
}

fn writeJsonString(writer: std.io.AnyWriter, value: []const u8) !void {
    try writer.writeByte('"');
    for (value) |c| {
        switch (c) {
            '\\' => try writer.writeAll("\\\\"),
            '"' => try writer.writeAll("\\\""),
            '\n' => try writer.writeAll("\\n"),
            '\r' => try writer.writeAll("\\r"),
            '\t' => try writer.writeAll("\\t"),
            else => try writer.writeByte(c),
        }
    }
    try writer.writeByte('"');
}

test "valid stability metadata manifest" {
    var report = try validateManifestText(std.testing.allocator, example_manifest_json);
    defer report.deinit();

    try std.testing.expect(report.valid);
    try std.testing.expectEqual(@as(usize, 5), report.label_count);
    try std.testing.expectEqual(@as(usize, 1), report.artifact_count);
    try std.testing.expectEqual(@as(usize, 1), report.evidence_count);
}

test "stability metadata rejects undeclared duplicate and unsafe path" {
    const manifest =
        \\
        \\{
        \\  "schema_version": 1,
        \\  "labels": [
        \\    { "name": "verified-sab-backend", "description": "one" },
        \\    { "name": "verified-sab-backend", "description": "two" }
        \\  ],
        \\  "artifacts": [
        \\    { "path": "../lib/demo.sla", "labels": ["missing-label"], "evidence": [{ "kind": "command", "status": "maybe" }] }
        \\  ]
        \\}
        \\
    ;
    var report = try validateManifestText(std.testing.allocator, manifest);
    defer report.deinit();

    try std.testing.expect(!report.valid);
    try std.testing.expect(report.errors.items.len >= 3);
}
