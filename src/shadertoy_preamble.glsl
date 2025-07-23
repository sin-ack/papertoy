// Adapted from https://github.com/ghostty-org/ghostty/blob/main/src/renderer/shaders/shadertoy_prefix.glsl
// Copyright (c) 2024 Mitchell Hashimoto, License: MIT
#version 430 core

layout(binding = 0) uniform Globals {
    uniform vec3    iResolution;
    uniform float   iTime;
    uniform float   iTimeDelta;
    uniform float   iFrameRate;
    uniform int     iFrame;
    uniform float   iChannelTime[4];
    uniform vec3    iChannelResolution[4];
    uniform vec4    iMouse;
    uniform vec4    iDate;
    uniform float   iSampleRate;
};

// Currently unused since we don't have a texture to sample from
// layout(binding = 0) uniform sampler2D    iChannel0;
// layout(binding = 1) uniform sampler2D    iChannel1;
// layout(binding = 2) uniform sampler2D    iChannel2;
// layout(binding = 3) uniform sampler2D    iChannel3;

layout(location = 0) in vec4 gl_FragCoord;
layout(location = 0) out vec4 _fragColor;

#define texture2D texture

void mainImage(out vec4 fragColor, in vec2 fragCoord);
void main() { mainImage (_fragColor, gl_FragCoord.xy); }
