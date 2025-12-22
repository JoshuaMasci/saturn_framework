#!/bin/bash
glslc -fshader-stage=vert triangle.vert.glsl -o triangle.vert.spv
glslc -fshader-stage=frag triangle.frag.glsl -o triangle.frag.spv
