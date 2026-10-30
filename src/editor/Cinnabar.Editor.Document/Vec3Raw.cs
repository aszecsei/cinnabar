using Cinnabar.Editor.Maths;

namespace Cinnabar.Editor.Document;

/// <summary>Vec3's conversions to and from raw World_Positions, which need the pose's unit.</summary>
public static class Vec3Raw
{
    extension(Vec3)
    {
        /// <summary>The meters from one raw World_Position to another.</summary>
        public static Vec3 Between(long[] from, long[] to) =>
            new((to[0] - from[0]) / Pose.Unit, (to[1] - from[1]) / Pose.Unit, (to[2] - from[2]) / Pose.Unit);
    }

    extension(Vec3 v)
    {
        /// <summary>A raw World_Position moved by this many meters.</summary>
        public long[] Offset(long[] position) =>
            [position[0] + (long)Math.Round(v.X * Pose.Unit), position[1] + (long)Math.Round(v.Y * Pose.Unit), position[2] + (long)Math.Round(v.Z * Pose.Unit)];
    }
}
