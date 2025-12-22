# Saturn Framework

A Zig-based game framework designed for high-performance 3D graphics.

## Description

Saturn Framework is a game development framework written in Zig that focuses on high performance 3D rendering.

## Requirements

- [Zig 0.15.1](https://ziglang.org/)

## Installation

Add Saturn Framework to your project using Zig's package manager by including it in your `build.zig.zon`:

```zig
.dependencies = .{
    .saturn_framework = .{
        .url = "https://github.com/JoshuaMasci/saturn_framework/archive/refs/heads/main.tar.gz",
        // Add the hash after first fetch
    },
},
```

Then in your `build.zig`, add the dependency:

```zig
const saturn = b.dependency("saturn_framework", .{
    .target = target,
    .optimize = optimize,
});
exe.root_module.addImport("saturn_framework", saturn.module("root"));
```

## Building and Running

### Build the project

```bash
zig build
```

### Run the triangle example

```bash
zig build run-triangle
```

## Examples

Check the `examples/` directory for sample applications demonstrating framework usage. The triangle example provides a basic introduction to rendering with Saturn Framework.

## License

This project is licensed under the MIT License - see the [LICENSE](LICENSE) file for details.
