#!/bin/bash
glslc -I ../../shader/glsl/ -fshader-stage=vert triangle.vert.glsl -o triangle.vert.spv
glslc -I ../../shader/glsl/ -fshader-stage=frag triangle.frag.glsl -o triangle.frag.spv
