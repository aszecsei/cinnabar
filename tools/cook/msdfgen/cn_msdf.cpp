// The C API that tools/cook calls to make a glyph's multi-channel and true signed distance field with msdfgen's core,
// whose own API is C++. A glyph is a list of outline commands, as vendor:stb/truetype gives them. Each call is
// independent of every other, so the cooker runs glyphs on all its threads. See docs/content/kinds/fonts.md#fonts.

#include <cstdint>
#include <exception>

#include "msdfgen.h"
#include "core/ShapeDistanceFinder.h"

using namespace msdfgen;

// Matches Msdf_Op in tools/cook/msdf.odin.
enum CnMsdfOp : uint32_t {
    CN_MSDF_MOVE = 1,
    CN_MSDF_LINE = 2,
    CN_MSDF_QUAD = 3,
    CN_MSDF_CUBIC = 4,
};

// Matches Msdf_Command in tools/cook/msdf.odin: the end point, and before it the control points that the op takes, in
// font units with y up.
struct CnMsdfCommand {
    uint32_t op;
    float x, y;
    float cx0, cy0;
    float cx1, cy1;
};

// Matches Msdf_Params in tools/cook/msdf.odin. A font unit at (u, v) lands on the pixel ((u + translate) * scale),
// counted from the bitmap's bottom left. range is the width of the distances that the field holds, in pixels: a value of
// 0.5 is the outline, and 0 and 1 are range / 2 pixels outside and inside it.
struct CnMsdfParams {
    int32_t width, height;
    double scale;
    double translate_x, translate_y;
    double range;
    double angle_threshold;
};

namespace {

// build_shape makes the commands into a shape, as msdfgen's FreeType import does: a move starts a contour, and an edge
// of no length is left out. It returns false for a shape that msdfgen cannot use.
bool build_shape(const CnMsdfCommand* commands, int count, Shape& shape) {
    Contour* contour = nullptr;
    Point2 position;
    for (int i = 0; i < count; i++) {
        const CnMsdfCommand& c = commands[i];
        Point2 end(c.x, c.y);
        switch (c.op) {
        case CN_MSDF_MOVE:
            if (!(contour && contour->edges.empty())) {
                contour = &shape.addContour();
            }
            position = end;
            break;
        case CN_MSDF_LINE:
            if (!contour) return false;
            if (end != position) {
                contour->addEdge(EdgeHolder(position, end));
                position = end;
            }
            break;
        case CN_MSDF_QUAD:
            if (!contour) return false;
            if (end != position) {
                contour->addEdge(EdgeHolder(position, Point2(c.cx0, c.cy0), end));
                position = end;
            }
            break;
        case CN_MSDF_CUBIC: {
            if (!contour) return false;
            Point2 c0(c.cx0, c.cy0), c1(c.cx1, c.cy1);
            if (end != position || crossProduct(c0 - end, c1 - end)) {
                contour->addEdge(EdgeHolder(position, c0, c1, end));
                position = end;
            }
            break;
        }
        default:
            return false;
        }
    }
    if (!shape.contours.empty() && shape.contours.back().edges.empty()) {
        shape.contours.pop_back();
    }
    return shape.validate();
}

// orient reverses every contour of a shape whose winding is inside out, which a point far outside the outline shows by
// a positive distance. This is what msdf-atlas-gen does, as fonts disagree about which winding fills.
void orient(Shape& shape) {
    Shape::Bounds b = shape.getBounds();
    Point2 outside(b.l - (b.r - b.l) - 1, b.b - (b.t - b.b) - 1);
    if (SimpleTrueShapeDistanceFinder::oneShotDistance(shape, outside) > 0) {
        for (Contour& contour : shape.contours) {
            contour.reverse();
        }
    }
}

} // namespace

extern "C" {

// cn_msdf_bounds gives the bounds of the commands' outline in font units: left, bottom, right and top. It returns 0 for
// an outline with no edges, such as a space's, and -1 for commands that make no shape.
int cn_msdf_bounds(const CnMsdfCommand* commands, int count, double* bounds) {
    try {
        Shape shape;
        if (!build_shape(commands, count, shape)) return -1;
        if (shape.edgeCount() == 0) return 0;
        Shape::Bounds b = shape.getBounds();
        bounds[0] = b.l;
        bounds[1] = b.b;
        bounds[2] = b.r;
        bounds[3] = b.t;
        return 1;
    } catch (const std::exception&) {
        return -1;
    }
}

// cn_msdf_mtsdf writes the multi-channel distance field of the commands' outline into red, green and blue, and its true
// distance into alpha: params.width * params.height pixels of four floats, from the top row down. The values are
// distances mapped by params.range, and are not clamped. It returns 0, or -1 for commands that make no shape.
int cn_msdf_mtsdf(const CnMsdfCommand* commands, int count, const CnMsdfParams* params, float* pixels) {
    try {
        Shape shape;
        if (!build_shape(commands, count, shape)) return -1;
        shape.normalize();
        orient(shape);
        edgeColoringInkTrap(shape, params->angle_threshold);
        Projection projection(Vector2(params->scale), Vector2(params->translate_x, params->translate_y));
        // msdfgen's range is in the shape's units.
        Range range(params->range / params->scale);
        SDFTransformation transformation(projection, DistanceMapping(range));
        BitmapSection<float, 4> output(pixels, params->width, params->height, Y_DOWNWARD);
        generateMTSDF(output, shape, transformation, MSDFGeneratorConfig(true));
        return 0;
    } catch (const std::exception&) {
        return -1;
    }
}

} // extern "C"
