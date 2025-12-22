const std = @import("std");

pub fn Graph(comptime NodeData: type, comptime EdgeData: type) type {
    return struct {
        const Self = @This();

        pub const Node = struct {
            index: u16,
            out_edges: std.ArrayList(u16) = .empty,
            in_edges: std.ArrayList(u16) = .empty,
            data: NodeData,
        };

        pub const Edge = struct {
            from: ?u16,
            to: u16,
            data: EdgeData,
        };

        pub const SortResult = struct {
            index: u16,
            level: u16,
        };

        gpa: std.mem.Allocator,
        nodes: std.ArrayList(Node) = .empty,
        edges: std.ArrayList(Edge) = .empty,

        pub fn init(gpa: std.mem.Allocator) Self {
            return .{
                .gpa = gpa,
            };
        }

        pub fn initCapacity(gpa: std.mem.Allocator, node_count: usize, edge_count: usize) error{OutOfMemory}!Self {
            var self = Self.init(gpa);

            try self.nodes.ensureTotalCapacity(gpa, node_count);
            try self.edges.ensureTotalCapacity(gpa, edge_count);

            return self;
        }

        pub fn deinit(self: *Self) void {
            for (self.nodes.items) |*node| {
                node.out_edges.deinit(self.gpa);
                node.in_edges.deinit(self.gpa);
            }
            self.nodes.deinit(self.gpa);
            self.edges.deinit(self.gpa);
        }

        pub fn addNode(self: *Self, data: NodeData) error{OutOfMemory}!u16 {
            const idx: u16 = @intCast(self.nodes.items.len);
            try self.nodes.append(self.gpa, .{
                .index = idx,
                .out_edges = .empty,
                .data = data,
            });
            return idx;
        }

        pub fn addEdge(self: *Self, from: u16, to: u16, data: EdgeData) error{OutOfMemory}!void {
            const edge_index: u16 = @intCast(self.edges.items.len);
            try self.edges.append(self.gpa, .{
                .from = from,
                .to = to,
                .data = data,
            });

            try self.nodes.items[from].out_edges.append(self.gpa, edge_index);
            try self.nodes.items[to].in_edges.append(self.gpa, edge_index);
        }

        pub fn topologicalSort(self: *Self, allocator: std.mem.Allocator) error{ OutOfMemory, CycleDetected }![]SortResult {
            const node_count = self.nodes.items.len;

            var indegree = try allocator.alloc(u16, node_count);
            defer allocator.free(indegree);
            @memset(indegree, 0);

            var level_table = try allocator.alloc(u16, node_count);
            defer allocator.free(level_table);
            @memset(level_table, 0);

            for (self.edges.items) |edge| {
                indegree[edge.to] += 1;
            }

            var queue: std.ArrayList(u16) = try .initCapacity(allocator, node_count);
            defer queue.deinit(allocator);

            for (self.nodes.items) |node| {
                if (indegree[node.index] == 0) {
                    try queue.append(allocator, node.index);
                }
            }

            var result: std.ArrayList(SortResult) = try .initCapacity(allocator, node_count);
            errdefer result.deinit(allocator);

            var qindex: usize = 0;
            while (qindex < queue.items.len) : (qindex += 1) {
                const node_index = queue.items[qindex];

                result.appendAssumeCapacity(.{
                    .index = node_index,
                    .level = level_table[node_index],
                });

                const node = self.nodes.items[node_index];

                for (node.out_edges.items) |edge_index| {
                    const edge = self.edges.items[edge_index];

                    indegree[edge.to] -= 1;

                    const new_level = level_table[node_index] + 1;
                    if (new_level > level_table[edge.to]) {
                        level_table[edge.to] = new_level;
                    }

                    if (indegree[edge.to] == 0) {
                        queue.appendAssumeCapacity(edge.to);
                    }
                }
            }

            if (result.items.len != node_count)
                return error.CycleDetected;

            return result.toOwnedSlice(allocator);
        }
    };
}
