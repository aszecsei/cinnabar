"""Renders a reference scene's image for tools/refdiff and exports its mesh (see docs/rendering/reference-scenes.md#making-a-reference).
It changes the scene in memory only, and writes nothing but its outputs.

usage: blender --background reference.blend --python render_reference.py -- <out_dir> [samples]
"""
import os
import sys

import bpy

argv = sys.argv[sys.argv.index("--") + 1:]
out = os.path.abspath(argv[0])
samples = int(argv[1]) if len(argv) > 1 else 4096
os.makedirs(out, exist_ok=True)
scene = bpy.context.scene

# GPU if there is one.
try:
    prefs = bpy.context.preferences.addons["cycles"].preferences
    for kind in ("OPTIX", "CUDA", "HIP", "ONEAPI", "METAL"):
        try:
            prefs.compute_device_type = kind
        except TypeError:
            continue
        prefs.get_devices()
        if any(d.type == kind for d in prefs.devices):
            for d in prefs.devices:
                d.use = d.type == kind
            scene.cycles.device = "GPU"
            print("DEVICE", kind)
            break
except Exception as e:
    print("DEVICE CPU", e)

# A plain perspective camera of the same lens and sensor, without depth of field.
cam = scene.camera.data
cam.type = "PERSP"
cam.dof.use_dof = False

# 1280 x 720, so the horizontal field of view is the same as at 1920 x 1080.
scene.render.resolution_x, scene.render.resolution_y, scene.render.resolution_percentage = 1280, 720, 100
c = scene.cycles
c.samples = samples
c.use_adaptive_sampling = False
c.sample_clamp_indirect = 0
c.sample_clamp_direct = 0
c.use_denoising = True

# The comparison image: no tone curve, one stop of exposure, 16-bit sRGB-encoded, so it decodes to scene-linear * 2.
scene.view_settings.view_transform = "Standard"
scene.view_settings.look = "None"
scene.view_settings.exposure = 1.0
scene.view_settings.gamma = 1.0
scene.render.image_settings.file_format = "PNG"
scene.render.image_settings.color_mode = "RGB"
scene.render.image_settings.color_depth = "16"
scene.render.filepath = os.path.join(out, "reference.png")
bpy.ops.render.render(write_still=True)

# The look that the original had, AgX at no exposure, 8-bit, to view.
scene.view_settings.view_transform = "AgX"
scene.view_settings.exposure = 0.0
scene.render.image_settings.color_depth = "8"
img = bpy.data.images["Render Result"]
img.save_render(os.path.join(out, "reference_agx.png"), scene=scene)

# The room's mesh alone, glTF with +Y up.
bpy.ops.object.select_all(action="DESELECT")
room = bpy.data.objects["Cube.001"]
room.select_set(True)
bpy.context.view_layer.objects.active = room
bpy.ops.export_scene.gltf(filepath=os.path.join(out, "reference_room.gltf"), export_format="GLTF_SEPARATE",
                          use_selection=True, export_yup=True, export_apply=True, export_materials="EXPORT",
                          export_cameras=False, export_lights=False)
print("DONE", out)
