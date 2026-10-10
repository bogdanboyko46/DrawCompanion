"""Pack a rigged character and its animation clips into one USDZ for RealityKit.

Meshy returns the rigged character and each animation as separate GLB files.
RealityKit only loads USD, and it handles one animation timeline per file most
reliably. So this lays every clip end to end on a single timeline, exports one
USDZ, and writes a manifest with each clip's time range. The app trims the
timeline back into clips with AnimationView(trimStart:trimEnd:).

Run with Blender's Python module (`pip install bpy usd-core`):

  python pack_usdz.py --base rigged.glb --clip idle=idle.glb --clip walk=walk.glb \
      --out character.usdz --manifest clips.json [--embedded] [--texture-size 2048]

--embedded also keeps animations that ship inside the base GLB.
"""

import argparse
import json
import os
import sys

import bpy

FPS = 30
GAP_FRAMES = 2  # keeps clips from blending into each other at their edges


def parse_args():
    argv = sys.argv[sys.argv.index("--") + 1:] if "--" in sys.argv else sys.argv[1:]
    p = argparse.ArgumentParser()
    p.add_argument("--base", required=True)
    p.add_argument("--clip", action="append", default=[], help="name=path.glb")
    p.add_argument("--loop", action="append", default=[], help="clip names that loop")
    p.add_argument("--out", required=True)
    p.add_argument("--manifest", required=True)
    p.add_argument("--embedded", action="store_true")
    p.add_argument("--texture-size", default="2048")
    return p.parse_args(argv)


def import_glb(path):
    before = set(bpy.data.objects)
    actions_before = set(bpy.data.actions)
    bpy.ops.import_scene.gltf(filepath=path)
    objects = [o for o in bpy.data.objects if o not in before]
    actions = [a for a in bpy.data.actions if a not in actions_before]
    return objects, actions


def first_armature(objects):
    arms = [o for o in objects if o.type == "ARMATURE"]
    if not arms:
        raise SystemExit("no armature found")
    # Prefer the armature that actually deforms the most vertices.
    def weight(arm):
        return sum(len(o.data.vertices) for o in objects
                   if o.type == "MESH" and any(m.type == "ARMATURE" and m.object == arm for m in o.modifiers))
    return max(arms, key=weight)


def remove_objects(objects):
    for o in objects:
        bpy.data.objects.remove(o, do_unlink=True)


def object_slot(action):
    for slot in action.slots:
        if slot.target_id_type == "OBJECT":
            return slot
    return action.slots[0] if len(action.slots) else None


def main():
    args = parse_args()
    bpy.ops.wm.read_factory_settings(use_empty=True)
    scene = bpy.context.scene
    scene.render.fps = FPS
    scene.render.fps_base = 1

    base_objects, base_actions = import_glb(args.base)
    armature = first_armature(base_objects)

    clips = []  # (name, action)
    if args.embedded:
        clips += [(a.name, a) for a in base_actions]
    else:
        for a in base_actions:
            bpy.data.actions.remove(a)

    for spec in args.clip:
        name, _, path = spec.partition("=")
        objects, actions = import_glb(path)
        # The clip file carries its own copy of the mesh; keep only the motion.
        arm = first_armature(objects) if any(o.type == "ARMATURE" for o in objects) else None
        chosen = None
        if arm and arm.animation_data and arm.animation_data.action:
            chosen = arm.animation_data.action
        elif actions:
            chosen = max(actions, key=lambda a: a.frame_range[1] - a.frame_range[0])
        for a in actions:
            a.use_fake_user = a is chosen
        remove_objects(objects)
        for a in actions:
            if a is not chosen and a.users == 0:
                bpy.data.actions.remove(a)
        if chosen is None:
            print(f"warning: clip {name} has no animation, skipped", file=sys.stderr)
            continue
        chosen.name = name
        clips.append((name, chosen))

    if not clips:
        raise SystemExit("no animation clips to pack")

    anim = armature.animation_data or armature.animation_data_create()
    anim.action = None
    for track in list(anim.nla_tracks):
        anim.nla_tracks.remove(track)
    track = anim.nla_tracks.new()
    track.name = "timeline"

    manifest_clips = []
    cursor = 0
    for name, action in clips:
        start, end = action.frame_range
        strip = track.strips.new(name, int(cursor), action)
        slot = object_slot(action)
        if slot is not None and strip.action_slot != slot:
            strip.action_slot = slot
        strip.action_frame_start = start
        strip.action_frame_end = end
        strip.extrapolation = "NOTHING"
        strip.blend_type = "REPLACE"
        length = end - start
        manifest_clips.append({
            "name": name,
            "start": cursor / FPS,
            "end": (cursor + length) / FPS,
            "loop": name in args.loop,
        })
        cursor = int(cursor + length) + GAP_FRAMES + 1

    scene.frame_start = 0
    scene.frame_end = max(1, cursor - GAP_FRAMES - 1)

    for o in base_objects:
        o.select_set(True)

    os.makedirs(os.path.dirname(os.path.abspath(args.out)), exist_ok=True)
    bpy.ops.wm.usd_export(
        filepath=args.out,
        export_animation=True,
        export_armatures=True,
        only_deform_bones=True,
        export_shapekeys=False,
        export_materials=True,
        generate_preview_surface=True,
        export_textures_mode="NEW",
        export_lights=False,
        export_cameras=False,
        convert_orientation=True,
        export_global_up_selection="Y",
        export_global_forward_selection="NEGATIVE_Z",
        triangulate_meshes=True,
        usdz_downscale_size=args.texture_size,
        root_prim_path="/Character",
    )

    manifest = {"fps": FPS, "clips": manifest_clips}
    with open(args.manifest, "w") as f:
        json.dump(manifest, f, indent=2)
    print(json.dumps(manifest))


if __name__ == "__main__":
    main()
