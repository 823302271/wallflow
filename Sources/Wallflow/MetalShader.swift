enum MetalShader {
    static let source = #"""
    #include <metal_stdlib>
    using namespace metal;

    struct VertexOutput {
        float4 position [[position]];
    };

    struct WallpaperUniforms {
        float2 resolution;
        float2 mouse;
        float time;
        float activity;
        float intensity;
        float padding;
    };

    vertex VertexOutput wallpaperVertex(uint vertexID [[vertex_id]]) {
        const float2 positions[3] = {
            float2(-1.0, -1.0),
            float2( 3.0, -1.0),
            float2(-1.0,  3.0)
        };

        VertexOutput output;
        output.position = float4(positions[vertexID], 0.0, 1.0);
        return output;
    }

    float hash21(float2 point) {
        point = fract(point * float2(123.34, 456.21));
        point += dot(point, point + 45.32);
        return fract(point.x * point.y);
    }

    fragment float4 wallpaperFragment(
        VertexOutput input [[stage_in]],
        constant WallpaperUniforms &uniforms [[buffer(0)]]
    ) {
        float2 uv = input.position.xy / uniforms.resolution;
        float aspect = uniforms.resolution.x / uniforms.resolution.y;
        float2 point = uv - 0.5;
        point.x *= aspect;

        float2 mouse = uniforms.mouse - 0.5;
        mouse.x *= aspect;

        float2 mouseDelta = point - mouse;
        float mouseDistance = max(length(mouseDelta), 0.001);
        float mouseInfluence = exp(-mouseDistance * 5.5);
        point += (mouseDelta / mouseDistance) * mouseInfluence
            * (0.018 + 0.035 * uniforms.activity);

        float3 charcoal = float3(0.018, 0.027, 0.033);
        float3 deepTeal = float3(0.020, 0.105, 0.105);
        float3 color = mix(charcoal, deepTeal, smoothstep(-0.55, 0.6, point.y));

        float time = uniforms.time * 0.38;
        float aquaLines = 0.0;
        float warmLines = 0.0;

        for (int index = 0; index < 5; index++) {
            float layer = float(index);
            float phase = layer * 1.43;
            float frequency = 3.2 + layer * 0.52;
            float wave = sin(point.x * frequency + time * (0.62 + layer * 0.04) + phase);
            wave += sin(point.x * 1.7 - time * 0.31 + phase) * 0.24;

            float baseline = -0.42 + layer * 0.19;
            float cursorBend = (mouse.y - baseline) * mouseInfluence
                * (0.12 + uniforms.activity * 0.25);
            float lineY = baseline + wave * 0.075 + cursorBend;
            float distanceToLine = abs(point.y - lineY);
            float line = 1.0 - smoothstep(0.002, 0.012, distanceToLine);
            float glow = exp(-distanceToLine * 65.0) * 0.16;

            if ((index & 1) == 0) {
                aquaLines += line * 0.62 + glow;
            } else {
                warmLines += line * 0.42 + glow * 0.75;
            }
        }

        float ripple = sin(mouseDistance * 56.0 - uniforms.time * 4.2);
        ripple *= exp(-mouseDistance * 7.0) * uniforms.activity;
        float rippleLine = smoothstep(0.78, 1.0, ripple) * 0.34;

        float2 gridPoint = point + (mouse - point) * 0.015;
        float2 gridCell = abs(fract(gridPoint * float2(9.0, 6.0)) - 0.5);
        float grid = smoothstep(0.495, 0.48, min(gridCell.x, gridCell.y)) * 0.045;

        color += float3(0.12, 0.78, 0.68) * (aquaLines + rippleLine);
        color += float3(0.96, 0.34, 0.18) * warmLines;
        color += float3(0.18, 0.28, 0.27) * grid;

        float vignette = 1.0 - smoothstep(0.42, 0.92, length((uv - 0.5) * float2(0.8, 1.0)));
        color *= 0.72 + 0.28 * vignette;

        float grain = hash21(input.position.xy + uniforms.time) - 0.5;
        color += grain * 0.012;
        return float4(color * uniforms.intensity, 1.0);
    }

    struct CanvasUniforms {
        float2 canvasSize;
    };

    struct CanvasShapeInstance {
        float2 positionA;
        float2 positionB;
        float2 positionC;
        float2 padding0;
        float4 color;
        float width;
        uint kind;
        float softness;
        float padding1;
    };

    struct CanvasShapeOutput {
        float4 position [[position]];
        float2 local;
        float2 parameters;
        float4 color;
        uint kind [[flat]];
        float softness;
    };

    vertex CanvasShapeOutput canvasShapeVertex(
        uint vertexID [[vertex_id]],
        uint instanceID [[instance_id]],
        constant CanvasUniforms &uniforms [[buffer(0)]],
        const device CanvasShapeInstance *instances [[buffer(1)]]
    ) {
        const float2 corners[6] = {
            float2(-1.0, -1.0), float2(1.0, -1.0), float2(-1.0, 1.0),
            float2(-1.0, 1.0), float2(1.0, -1.0), float2(1.0, 1.0)
        };
        CanvasShapeInstance instance = instances[instanceID];
        float2 pixel = instance.positionA;
        float2 local = float2(0.0);
        float2 parameters = float2(0.0);

        if (instance.kind == 0) {
            float2 delta = instance.positionB - instance.positionA;
            float lengthValue = max(length(delta), 0.001);
            float2 direction = delta / lengthValue;
            float2 perpendicular = float2(-direction.y, direction.x);
            float halfLength = lengthValue * 0.5;
            float halfWidth = max(instance.width * 0.5, 0.5);
            float2 extent = float2(
                halfLength + halfWidth + instance.softness,
                halfWidth + instance.softness
            );
            local = corners[vertexID] * extent;
            pixel = (instance.positionA + instance.positionB) * 0.5
                + direction * local.x + perpendicular * local.y;
            parameters = float2(halfLength, halfWidth);
        } else if (instance.kind == 1) {
            float radius = max(instance.positionB.x, 0.5);
            float extent = radius + instance.softness;
            local = corners[vertexID] * extent;
            pixel = instance.positionA + local;
            parameters = float2(radius, instance.width);
        } else if (instance.kind == 2) {
            const uint triangleIndices[6] = { 0, 1, 2, 2, 2, 2 };
            const float2 points[3] = {
                instance.positionA, instance.positionB, instance.positionC
            };
            pixel = points[triangleIndices[vertexID]];
        } else {
            local = corners[vertexID];
            pixel = (local * 0.5 + 0.5) * uniforms.canvasSize;
        }

        float2 ndc = float2(
            pixel.x / uniforms.canvasSize.x * 2.0 - 1.0,
            1.0 - pixel.y / uniforms.canvasSize.y * 2.0
        );
        CanvasShapeOutput output;
        output.position = float4(ndc, 0.0, 1.0);
        output.local = local;
        output.parameters = parameters;
        output.color = instance.color;
        output.kind = instance.kind;
        output.softness = max(instance.softness, 0.75);
        return output;
    }

    fragment float4 canvasShapeFragment(CanvasShapeOutput input [[stage_in]]) {
        float alpha = input.color.a;
        if (input.kind == 0) {
            float2 capsule = float2(
                max(abs(input.local.x) - input.parameters.x, 0.0),
                input.local.y
            );
            float distanceToShape = length(capsule) - input.parameters.y;
            alpha *= 1.0 - smoothstep(
                -input.softness * 0.5,
                input.softness * 0.5,
                distanceToShape
            );
        } else if (input.kind == 1) {
            float radialDistance = length(input.local);
            float outerDistance = radialDistance - input.parameters.x;
            float outerAlpha = 1.0 - smoothstep(
                -input.softness * 0.5,
                input.softness * 0.5,
                outerDistance
            );
            if (input.parameters.y > 0.0) {
                float innerRadius = max(input.parameters.x - input.parameters.y, 0.0);
                float innerDistance = radialDistance - innerRadius;
                float innerAlpha = 1.0 - smoothstep(
                    -input.softness * 0.5,
                    input.softness * 0.5,
                    innerDistance
                );
                alpha *= max(outerAlpha - innerAlpha, 0.0);
            } else {
                alpha *= outerAlpha;
            }
        } else if (input.kind == 3) {
            float radius = length(input.local * float2(0.72, 1.0));
            alpha *= smoothstep(0.52, 1.16, radius);
        }

        if (alpha < 0.001) discard_fragment();
        return float4(input.color.rgb * alpha, alpha);
    }
    """#
}
