#include <RealityKit/RealityKit.h>

[[visible]] void earthAtmosphere(realitykit::surface_parameters parameters) {
    auto geometry = parameters.geometry();
    auto surface = parameters.surface();
    float3 center = (parameters.uniforms().model_to_world() * float4(0, 0, 0, 1)).xyz;
    float3 radial = normalize(geometry.world_position() - center);
    float facing = saturate(dot(radial, normalize(geometry.view_direction())));
    // A single smooth rim that fades at both the surface center and outer silhouette.
    float opacity = 2.0 * facing * pow(1.0 - facing, 3.0);
    surface.set_emissive_color(half3(0.18, 0.42, 1.0));
    surface.set_opacity(half(opacity));
}
