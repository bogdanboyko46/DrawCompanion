"""Build the mock-mode character: a small rigged creature with four clips (idle, walk, greet, happy).

Mock mode serves this so the whole app (capture, generation UI, AR placement,
animation, behaviors) works without API keys. It also exercises the same
GLB -> pack_usdz.py path that real Meshy output takes.

  python scripts/make_mock_character.py  # writes server/character/fixtures/mock.glb
"""

import math
import os
import sys

import bpy
from mathutils import Vector

HERE = os.path.dirname(os.path.abspath(__file__))
OUT = os.path.join(HERE, "..", "server", "character", "fixtures", "mock.glb")
FPS = 30


def material(name, rgb, rough=0.55, emission=None):
    m = bpy.data.materials.new(name)
    bsdf = m.node_tree.nodes["Principled BSDF"]
    bsdf.inputs["Base Color"].default_value = (*rgb, 1)
    bsdf.inputs["Roughness"].default_value = rough
    return m


def shade_smooth(obj):
    for p in obj.data.polygons:
        p.use_smooth = True


def sphere(name, loc, scale, mat, bone, segments=32):
    bpy.ops.mesh.primitive_uv_sphere_add(segments=segments, ring_count=segments // 2, location=loc)
    o = bpy.context.object
    o.name = name
    o.scale = scale
    bpy.ops.object.transform_apply(scale=True)
    o.data.materials.append(mat)
    shade_smooth(o)
    rigid(o, bone)
    return o


def rigid(obj, bone):
    """Bind every vertex of a part to one bone, so eyes, feet etc. never smear."""
    if bone is None:
        return
    g = obj.vertex_groups.new(name=bone)
    g.add(range(len(obj.data.vertices)), 1.0, "REPLACE")


def ramp(z, lo, hi):
    return min(1.0, max(0.0, (z - lo) / (hi - lo)))


def soft_body_weights(obj):
    """The torus-like blob bends: hips at the bottom, chest in the middle, head on top."""
    groups = {n: obj.vertex_groups.new(name=n) for n in ("hips", "chest", "head")}
    for v in obj.data.vertices:
        z = (obj.matrix_world @ v.co).z
        head = ramp(z, 0.72, 0.9)
        chest = ramp(z, 0.42, 0.62) * (1 - head)
        hips = 1 - head - chest
        for name, w in (("hips", hips), ("chest", chest), ("head", head)):
            if w > 0.001:
                groups[name].add([v.index], w, "REPLACE")


def build_mesh():
    body_mat = material("Body", (0.98, 0.5, 0.18))
    belly_mat = material("Belly", (1.0, 0.86, 0.6))
    dark = material("Ink", (0.03, 0.03, 0.05), rough=0.25)
    white = material("Shine", (1, 1, 1), rough=0.2)
    cheek = material("Cheek", (1.0, 0.4, 0.45))

    parts = []
    body = sphere("body", (0, 0, 0.62), (0.42, 0.38, 0.5), body_mat, None, 48)
    soft_body_weights(body)
    parts.append(body)
    belly = sphere("belly", (0, -0.2, 0.52), (0.28, 0.22, 0.3), belly_mat, None)
    soft_body_weights(belly)
    parts.append(belly)
    for side, tag in ((1, "L"), (-1, "R")):
        parts.append(sphere(f"eye.{tag}", (0.15 * side, -0.33, 0.84), (0.085, 0.06, 0.11), dark, "head"))
        parts.append(sphere(f"shine.{tag}", (0.13 * side + 0.02, -0.385, 0.88), (0.025, 0.012, 0.03), white, "head", 16))
        parts.append(sphere(f"cheek.{tag}", (0.25 * side, -0.29, 0.72), (0.06, 0.03, 0.04), cheek, "head", 16))
        parts.append(sphere(f"ear.{tag}", (0.24 * side, 0.0, 1.12), (0.09, 0.07, 0.16), body_mat, f"ear.{tag}"))
        parts.append(sphere(f"arm.{tag}", (0.55 * side, -0.02, 0.6), (0.17, 0.075, 0.075), body_mat, f"arm.{tag}"))
        parts.append(sphere(f"foot.{tag}", (0.17 * side, -0.05, 0.08), (0.12, 0.17, 0.08), dark, f"leg.{tag}"))
        parts.append(sphere(f"leg.{tag}", (0.17 * side, 0, 0.2), (0.09, 0.09, 0.14), body_mat, f"leg.{tag}"))
    # A small smile: the lower half of a thin torus.
    bpy.ops.mesh.primitive_torus_add(major_radius=0.06, minor_radius=0.013, location=(0, -0.385, 0.75),
                                     rotation=(math.radians(90), 0, 0))
    smile = bpy.context.object
    smile.data.materials.append(dark)
    bpy.ops.object.mode_set(mode="EDIT")
    bpy.ops.mesh.select_all(action="DESELECT")
    bpy.ops.object.mode_set(mode="OBJECT")
    for v in smile.data.vertices:
        v.select = v.co.y > -0.01
    bpy.ops.object.mode_set(mode="EDIT")
    bpy.ops.mesh.delete(type="VERT")
    bpy.ops.object.mode_set(mode="OBJECT")
    shade_smooth(smile)
    rigid(smile, "head")
    parts.append(smile)

    bpy.ops.object.select_all(action="DESELECT")
    for p in parts:
        p.select_set(True)
    bpy.context.view_layer.objects.active = body
    bpy.ops.object.join()
    body.name = "Doodle"
    return body


def build_armature():
    bpy.ops.object.armature_add(location=(0, 0, 0))
    arm = bpy.context.object
    arm.name = "Rig"
    bpy.ops.object.mode_set(mode="EDIT")
    eb = arm.data.edit_bones
    root = eb[0]
    root.name = "root"
    root.head, root.tail = (0, 0, 0), (0, 0.15, 0)

    def bone(name, head, tail, parent):
        b = eb.new(name)
        b.head, b.tail = head, tail
        b.parent = eb[parent]
        return b

    bone("hips", (0, 0, 0.25), (0, 0, 0.5), "root")
    bone("chest", (0, 0, 0.5), (0, 0, 0.72), "hips")
    bone("head", (0, 0, 0.72), (0, 0, 1.1), "chest")
    for side, s in (("L", 1), ("R", -1)):
        bone(f"arm.{side}", (0.4 * s, -0.02, 0.6), (0.72 * s, -0.02, 0.6), "chest")
        bone(f"leg.{side}", (0.17 * s, 0, 0.32), (0.17 * s, 0, 0.04), "hips")
        bone(f"ear.{side}", (0.22 * s, 0, 1.0), (0.26 * s, 0, 1.25), "head")
    bpy.ops.object.mode_set(mode="OBJECT")
    arm.data.bones["root"].use_deform = False
    return arm


def key(pb, frame, rot=None, loc=None, scale=None):
    pb.rotation_mode = "XYZ"
    if rot is not None:
        pb.rotation_euler = [math.radians(a) for a in rot]
        pb.keyframe_insert("rotation_euler", frame=frame)
    if loc is not None:
        pb.location = loc
        pb.keyframe_insert("location", frame=frame)
    if scale is not None:
        pb.scale = scale
        pb.keyframe_insert("scale", frame=frame)


def reset_pose(arm):
    for pb in arm.pose.bones:
        pb.rotation_mode = "XYZ"
        pb.rotation_euler = (0, 0, 0)
        pb.location = (0, 0, 0)
        pb.scale = (1, 1, 1)


def new_action(arm, name):
    reset_pose(arm)
    act = bpy.data.actions.new(name)
    act.use_fake_user = True
    arm.animation_data.action = act
    return act


def make_clips(arm):
    arm.animation_data_create()
    P = arm.pose.bones

    # Bone axes (from the rest pose): Y runs along each bone. For the arms, local X
    # raises (+) or lowers (-) the arm and local Z swings it (arm.L: - is forward,
    # arm.R: + is forward). Legs step about local X. hips local Y is world up, so
    # hips location (0, h, 0) lifts the body; rotation about Z is a sideways lean.
    DOWN = -55

    # idle: breathe, sway, ear wiggle. 2 s loop.
    new_action(arm, "idle")
    for f, t in ((0, 0), (15, 1), (30, 0), (45, -1), (60, 0)):
        a = abs(t)
        key(P["hips"], f, scale=(1 + 0.025 * a, 1 - 0.035 * a, 1 + 0.025 * a))
        key(P["chest"], f, rot=(0, 0, 3 * t))
        key(P["head"], f, rot=(0, 0, -6 * t))
        key(P["ear.L"], f, rot=(0, 0, -10 * t))
        key(P["ear.R"], f, rot=(0, 0, -10 * t))
        key(P["arm.L"], f, rot=(DOWN + 6 * a, 0, 0))
        key(P["arm.R"], f, rot=(DOWN + 6 * a, 0, 0))

    # walk: alternate legs, bob, counter-swing arms. 0.8 s loop.
    new_action(arm, "walk")
    for f, s in ((0, 1), (6, 0), (12, -1), (18, 0), (24, 1)):
        bob = 0.035 if s == 0 else 0.0
        key(P["hips"], f, loc=(0, bob, 0), rot=(0, 7 * s, 0))
        key(P["leg.L"], f, rot=(-32 * s, 0, 0))
        key(P["leg.R"], f, rot=(32 * s, 0, 0))
        key(P["arm.L"], f, rot=(DOWN + 5, 0, -28 * s))
        key(P["arm.R"], f, rot=(DOWN + 5, 0, -28 * s))
        key(P["head"], f, rot=(0, 0, 4 * s))

    # greet: raise the right arm and wave three times. 1.6 s.
    new_action(arm, "greet")
    for f in (0, 48):
        key(P["arm.L"], f, rot=(DOWN, 0, 0))
        key(P["arm.R"], f, rot=(DOWN, 0, 0))
        key(P["head"], f, rot=(0, 0, 0))
    key(P["arm.R"], 8, rot=(50, 0, 10))
    for i, f in enumerate(range(13, 41, 5)):
        key(P["arm.R"], f, rot=(65 if i % 2 else 35, 0, 15))
    key(P["head"], 12, rot=(0, -14, -10))
    key(P["head"], 38, rot=(0, -14, -10))
    key(P["arm.L"], 24, rot=(DOWN + 10, 0, 0))

    # happy: a jump. Anticipate (squash), launch (stretch), land (squash), settle. 1.2 s.
    new_action(arm, "happy")
    seq = (
        (0, 0.0, (1, 1, 1), DOWN, 0),
        (8, 0.0, (1.16, 0.8, 1.16), DOWN - 15, 0),
        (14, 0.38, (0.88, 1.2, 0.88), 45, 28),
        (20, 0.48, (1, 1, 1), 50, 28),
        (26, 0.0, (1.2, 0.76, 1.2), DOWN + 10, 0),
        (32, 0.0, (0.96, 1.05, 0.96), DOWN, 0),
        (36, 0.0, (1, 1, 1), DOWN, 0),
    )
    for f, h, sc, arm_x, tuck in seq:
        key(P["hips"], f, loc=(0, h, 0), scale=sc)
        key(P["arm.L"], f, rot=(arm_x, 0, 0))
        key(P["arm.R"], f, rot=(arm_x, 0, 0))
        key(P["leg.L"], f, rot=(tuck, 0, 0))
        key(P["leg.R"], f, rot=(tuck, 0, 0))

    arm.animation_data.action = None
    reset_pose(arm)


def main():
    bpy.ops.wm.read_factory_settings(use_empty=True)
    bpy.context.scene.render.fps = FPS
    mesh = build_mesh()
    arm = build_armature()
    mesh.parent = arm
    mod = mesh.modifiers.new("Armature", "ARMATURE")
    mod.object = arm
    make_clips(arm)
    # Push each action to its own NLA track so the glTF exporter writes them all.
    for act in [a for a in bpy.data.actions]:
        t = arm.animation_data.nla_tracks.new()
        t.name = act.name
        t.strips.new(act.name, 0, act)
    os.makedirs(os.path.dirname(OUT), exist_ok=True)
    bpy.ops.export_scene.gltf(filepath=OUT, export_format="GLB", export_animations=True,
                              export_animation_mode="NLA_TRACKS", export_yup=True)
    if "--blend" in sys.argv:
        bpy.ops.wm.save_as_mainfile(filepath=OUT.replace(".glb", ".blend"))
    print("wrote", OUT)


if __name__ == "__main__":
    main()
