/* SPDX-License-Identifier: MIT OR Apache-2.0 */
/*
 * GLU, Finch's own (Libraries/libGLU.dylib, re-exported by OpenGL.framework as Apple's
 * is): projections (gluPerspective, gluOrtho2D, gluLookAt, gluPickMatrix), coordinate
 * mapping (gluProject, gluUnProject, gluUnProject4), quadrics (spheres, cylinders,
 * disks and partial disks in every draw style, with normals, orientation and texture
 * coordinates), image scaling and mipmaps (gluScaleImage, gluBuild1D/2DMipmaps), and
 * error and version strings. Quadrics are drawn with immediate-mode GL: slices around
 * the z axis, stacks along it (loops outward for disks), as the GLU specification
 * describes. NURBS and the tessellator aren't here yet.
 */
#include <OpenGL/gl.h>
#include <OpenGL/glu.h>
#include <math.h>
#include <stdbool.h>
#include <stdlib.h>
#include <string.h>

#define FINCH_EXPORT __attribute__((visibility("default")))

#pragma mark - Matrices

FINCH_EXPORT void
gluOrtho2D(GLdouble left, GLdouble right, GLdouble bottom, GLdouble top)
{
    glOrtho(left, right, bottom, top, -1, 1);
}

FINCH_EXPORT void
gluPerspective(GLdouble fovy, GLdouble aspect, GLdouble zNear, GLdouble zFar)
{
    double radians = fovy / 2 * M_PI / 180;
    double dz = zFar - zNear, s = sin(radians);
    if (dz == 0 || s == 0 || aspect == 0)
        return;
    double cotangent = cos(radians) / s;
    GLdouble m[16] = {0};
    m[0] = cotangent / aspect;
    m[5] = cotangent;
    m[10] = -(zFar + zNear) / dz;
    m[11] = -1;
    m[14] = -2 * zNear * zFar / dz;
    glMultMatrixd(m);
}

static void
normalize(double v[3])
{
    double r = sqrt(v[0] * v[0] + v[1] * v[1] + v[2] * v[2]);
    if (r == 0)
        return;
    v[0] /= r, v[1] /= r, v[2] /= r;
}

static void
cross(const double a[3], const double b[3], double out[3])
{
    out[0] = a[1] * b[2] - a[2] * b[1];
    out[1] = a[2] * b[0] - a[0] * b[2];
    out[2] = a[0] * b[1] - a[1] * b[0];
}

FINCH_EXPORT void
gluLookAt(GLdouble eyeX, GLdouble eyeY, GLdouble eyeZ, GLdouble centerX, GLdouble centerY, GLdouble centerZ, GLdouble upX, GLdouble upY,
          GLdouble upZ)
{
    double forward[3] = {centerX - eyeX, centerY - eyeY, centerZ - eyeZ}, up[3] = {upX, upY, upZ}, side[3];
    normalize(forward);
    cross(forward, up, side);
    normalize(side);
    cross(side, forward, up);
    GLdouble m[16] = {side[0], up[0], -forward[0], 0, side[1], up[1], -forward[1], 0, side[2], up[2], -forward[2], 0, 0, 0, 0, 1};
    glMultMatrixd(m);
    glTranslated(-eyeX, -eyeY, -eyeZ);
}

FINCH_EXPORT void
gluPickMatrix(GLdouble x, GLdouble y, GLdouble delX, GLdouble delY, GLint viewport[4])
{
    if (delX <= 0 || delY <= 0)
        return;
    glTranslated((viewport[2] - 2 * (x - viewport[0])) / delX, (viewport[3] - 2 * (y - viewport[1])) / delY, 0);
    glScaled(viewport[2] / delX, viewport[3] / delY, 1);
}

/* out = m * in (column-major, as GL's) */
static void
transform(const GLdouble m[16], const double in[4], double out[4])
{
    for (int i = 0; i < 4; i++)
        out[i] = in[0] * m[0 * 4 + i] + in[1] * m[1 * 4 + i] + in[2] * m[2 * 4 + i] + in[3] * m[3 * 4 + i];
}

static void
multiply(const GLdouble a[16], const GLdouble b[16], GLdouble r[16])
{
    for (int i = 0; i < 4; i++)
        for (int j = 0; j < 4; j++)
            r[i * 4 + j] = a[i * 4 + 0] * b[0 * 4 + j] + a[i * 4 + 1] * b[1 * 4 + j] + a[i * 4 + 2] * b[2 * 4 + j] + a[i * 4 + 3] * b[3 * 4 + j];
}

/* Gauss-Jordan inversion of a 4x4 matrix; false if it's singular. */
static bool
invert(const GLdouble m[16], GLdouble inv[16])
{
    double a[4][8];
    for (int i = 0; i < 4; i++)
        for (int j = 0; j < 4; j++) {
            a[i][j] = m[j * 4 + i];
            a[i][j + 4] = i == j;
        }
    for (int c = 0; c < 4; c++) {
        int p = c;
        for (int r = c + 1; r < 4; r++)
            if (fabs(a[r][c]) > fabs(a[p][c]))
                p = r;
        if (fabs(a[p][c]) < 1e-300)
            return false;
        if (p != c)
            for (int k = 0; k < 8; k++) {
                double t = a[c][k];
                a[c][k] = a[p][k], a[p][k] = t;
            }
        double d = a[c][c];
        for (int k = 0; k < 8; k++)
            a[c][k] /= d;
        for (int r = 0; r < 4; r++)
            if (r != c) {
                double f = a[r][c];
                for (int k = 0; k < 8; k++)
                    a[r][k] -= f * a[c][k];
            }
    }
    for (int i = 0; i < 4; i++)
        for (int j = 0; j < 4; j++)
            inv[j * 4 + i] = a[i][j + 4];
    return true;
}

FINCH_EXPORT GLint
gluProject(GLdouble objX, GLdouble objY, GLdouble objZ, const GLdouble model[16], const GLdouble proj[16], const GLint view[4],
           GLdouble *winX, GLdouble *winY, GLdouble *winZ)
{
    double in[4] = {objX, objY, objZ, 1}, eye[4], clip[4];
    transform(model, in, eye);
    transform(proj, eye, clip);
    if (clip[3] == 0)
        return GL_FALSE;
    for (int i = 0; i < 3; i++)
        clip[i] /= clip[3];
    *winX = view[0] + (clip[0] * 0.5 + 0.5) * view[2];
    *winY = view[1] + (clip[1] * 0.5 + 0.5) * view[3];
    *winZ = clip[2] * 0.5 + 0.5;
    return GL_TRUE;
}

FINCH_EXPORT GLint
gluUnProject4(GLdouble winX, GLdouble winY, GLdouble winZ, GLdouble clipW, const GLdouble model[16], const GLdouble proj[16],
              const GLint view[4], GLdouble nearVal, GLdouble farVal, GLdouble *objX, GLdouble *objY, GLdouble *objZ, GLdouble *objW)
{
    GLdouble both[16], inv[16];
    multiply(model, proj, both);
    if (!invert(both, inv))
        return GL_FALSE;
    double in[4] = {(winX - view[0]) / view[2] * 2 - 1, (winY - view[1]) / view[3] * 2 - 1,
                    (winZ - nearVal) / (farVal - nearVal) * 2 - 1, clipW}, out[4];
    transform(inv, in, out);
    *objX = out[0], *objY = out[1], *objZ = out[2], *objW = out[3];
    return GL_TRUE;
}

FINCH_EXPORT GLint
gluUnProject(GLdouble winX, GLdouble winY, GLdouble winZ, const GLdouble model[16], const GLdouble proj[16], const GLint view[4],
             GLdouble *objX, GLdouble *objY, GLdouble *objZ)
{
    GLdouble both[16], inv[16];
    multiply(model, proj, both);
    if (!invert(both, inv))
        return GL_FALSE;
    double in[4] = {(winX - view[0]) / view[2] * 2 - 1, (winY - view[1]) / view[3] * 2 - 1, winZ * 2 - 1, 1}, out[4];
    transform(inv, in, out);
    if (out[3] == 0)
        return GL_FALSE;
    *objX = out[0] / out[3], *objY = out[1] / out[3], *objZ = out[2] / out[3];
    return GL_TRUE;
}

#pragma mark - Quadrics

struct GLUquadric {
    GLenum drawStyle, normals, orientation;
    GLboolean texture;
    void (*errorCallback)(GLenum);
};

FINCH_EXPORT GLUquadric *
gluNewQuadric(void)
{
    GLUquadric *q = calloc(1, sizeof *q);
    if (q) {
        q->drawStyle = GLU_FILL;
        q->normals = GLU_SMOOTH;
        q->orientation = GLU_OUTSIDE;
    }
    return q;
}

FINCH_EXPORT void gluDeleteQuadric(GLUquadric *quad) { free(quad); }
FINCH_EXPORT void gluQuadricDrawStyle(GLUquadric *quad, GLenum draw) { if (quad) quad->drawStyle = draw; }
FINCH_EXPORT void gluQuadricNormals(GLUquadric *quad, GLenum normal) { if (quad) quad->normals = normal; }
FINCH_EXPORT void gluQuadricOrientation(GLUquadric *quad, GLenum orientation) { if (quad) quad->orientation = orientation; }
FINCH_EXPORT void gluQuadricTexture(GLUquadric *quad, GLboolean texture) { if (quad) quad->texture = texture; }

FINCH_EXPORT void
gluQuadricCallback(GLUquadric *quad, GLenum which, void (*fn)(void))
{
    if (quad && which == GLU_ERROR)
        quad->errorCallback = (void (*)(GLenum))fn;
}

static void
normal3(GLUquadric *q, double x, double y, double z)
{
    if (q->normals == GLU_NONE)
        return;
    if (q->orientation == GLU_INSIDE)
        x = -x, y = -y, z = -z;
    glNormal3d(x, y, z);
}

static void
texcoord(GLUquadric *q, double s, double t)
{
    if (q->texture)
        glTexCoord2d(s, t);
}

FINCH_EXPORT void
gluCylinder(GLUquadric *q, GLdouble base, GLdouble top, GLdouble height, GLint slices, GLint stacks)
{
    if (!q || slices < 2 || stacks < 1 || base < 0 || top < 0 || height < 0)
        return;
    double nz = (base - top) / height, nlen = sqrt(1 + nz * nz);
    if (q->drawStyle == GLU_POINT) {
        glBegin(GL_POINTS);
        for (int j = 0; j <= stacks; j++) {
            double z = height * j / stacks, r = base + (top - base) * j / stacks;
            for (int i = 0; i < slices; i++) {
                double a = 2 * M_PI * i / slices;
                normal3(q, sin(a) / nlen, cos(a) / nlen, nz / nlen);
                glVertex3d(r * sin(a), r * cos(a), z);
            }
        }
        glEnd();
        return;
    }
    if (q->drawStyle == GLU_LINE || q->drawStyle == GLU_SILHOUETTE) {
        for (int j = 0; j <= stacks; j++) {
            if (q->drawStyle == GLU_SILHOUETTE && j != 0 && j != stacks)
                continue;
            double z = height * j / stacks, r = base + (top - base) * j / stacks;
            glBegin(GL_LINE_LOOP);
            for (int i = 0; i < slices; i++) {
                double a = 2 * M_PI * i / slices;
                normal3(q, sin(a) / nlen, cos(a) / nlen, nz / nlen);
                glVertex3d(r * sin(a), r * cos(a), z);
            }
            glEnd();
        }
        glBegin(GL_LINES);
        for (int i = 0; i < slices; i++) {
            double a = 2 * M_PI * i / slices;
            normal3(q, sin(a) / nlen, cos(a) / nlen, nz / nlen);
            glVertex3d(base * sin(a), base * cos(a), 0);
            glVertex3d(top * sin(a), top * cos(a), height);
        }
        glEnd();
        return;
    }
    for (int j = 0; j < stacks; j++) {
        double z0 = height * j / stacks, z1 = height * (j + 1) / stacks;
        double r0 = base + (top - base) * j / stacks, r1 = base + (top - base) * (j + 1) / stacks;
        glBegin(GL_QUAD_STRIP);
        for (int i = 0; i <= slices; i++) {
            double a = 2 * M_PI * (i == slices ? 0 : i) / slices;
            double s = (double)i / slices;
            normal3(q, sin(a) / nlen, cos(a) / nlen, nz / nlen);
            if (q->orientation == GLU_INSIDE) {
                texcoord(q, 1 - s, (double)(j + 1) / stacks);
                glVertex3d(r1 * sin(a), r1 * cos(a), z1);
                texcoord(q, 1 - s, (double)j / stacks);
                glVertex3d(r0 * sin(a), r0 * cos(a), z0);
            } else {
                texcoord(q, s, (double)j / stacks);
                glVertex3d(r0 * sin(a), r0 * cos(a), z0);
                texcoord(q, s, (double)(j + 1) / stacks);
                glVertex3d(r1 * sin(a), r1 * cos(a), z1);
            }
        }
        glEnd();
    }
}

FINCH_EXPORT void
gluPartialDisk(GLUquadric *q, GLdouble inner, GLdouble outer, GLint slices, GLint loops, GLdouble start, GLdouble sweep)
{
    if (!q || slices < 2 || loops < 1 || outer <= 0 || inner < 0 || inner > outer)
        return;
    if (sweep < -360)
        sweep = -360;
    if (sweep > 360)
        sweep = 360;
    if (sweep < 0) {
        start += sweep;
        sweep = -sweep;
    }
    normal3(q, 0, 0, 1);
    double a0 = start * M_PI / 180, da = sweep * M_PI / 180 / slices;
    bool full = sweep == 360;
    if (q->drawStyle == GLU_POINT) {
        glBegin(GL_POINTS);
        for (int j = 0; j <= loops; j++) {
            double r = inner + (outer - inner) * j / loops;
            for (int i = 0; i < (full ? slices : slices + 1); i++) {
                double a = a0 + i * da;
                texcoord(q, r / outer / 2 * sin(a) + 0.5, r / outer / 2 * cos(a) + 0.5);
                glVertex2d(r * sin(a), r * cos(a));
            }
        }
        glEnd();
        return;
    }
    if (q->drawStyle == GLU_LINE || q->drawStyle == GLU_SILHOUETTE) {
        for (int j = 0; j <= loops; j++) {
            if (q->drawStyle == GLU_SILHOUETTE && j != 0 && j != loops)
                continue;
            double r = inner + (outer - inner) * j / loops;
            if (r == 0)
                continue;
            glBegin(full ? GL_LINE_LOOP : GL_LINE_STRIP);
            for (int i = 0; i < (full ? slices : slices + 1); i++) {
                double a = a0 + i * da;
                glVertex2d(r * sin(a), r * cos(a));
            }
            glEnd();
        }
        if (q->drawStyle == GLU_LINE || !full) {
            glBegin(GL_LINES);
            for (int i = 0; i <= slices; i++) {
                if (q->drawStyle == GLU_SILHOUETTE && i != 0 && i != slices)
                    continue;
                if (full && i == slices)
                    break;
                double a = a0 + i * da;
                glVertex2d(inner * sin(a), inner * cos(a));
                glVertex2d(outer * sin(a), outer * cos(a));
            }
            glEnd();
        }
        return;
    }
    for (int j = 0; j < loops; j++) {
        double r0 = inner + (outer - inner) * j / loops, r1 = inner + (outer - inner) * (j + 1) / loops;
        glBegin(GL_QUAD_STRIP);
        for (int i = 0; i <= slices; i++) {
            double a = a0 + i * da;
            double s = sin(a), c = cos(a);
            if (q->orientation == GLU_INSIDE) {
                texcoord(q, r0 / outer / 2 * s + 0.5, r0 / outer / 2 * c + 0.5);
                glVertex2d(r0 * s, r0 * c);
                texcoord(q, r1 / outer / 2 * s + 0.5, r1 / outer / 2 * c + 0.5);
                glVertex2d(r1 * s, r1 * c);
            } else {
                texcoord(q, r1 / outer / 2 * s + 0.5, r1 / outer / 2 * c + 0.5);
                glVertex2d(r1 * s, r1 * c);
                texcoord(q, r0 / outer / 2 * s + 0.5, r0 / outer / 2 * c + 0.5);
                glVertex2d(r0 * s, r0 * c);
            }
        }
        glEnd();
    }
}

FINCH_EXPORT void
gluDisk(GLUquadric *q, GLdouble inner, GLdouble outer, GLint slices, GLint loops)
{
    gluPartialDisk(q, inner, outer, slices, loops, 0, 360);
}

FINCH_EXPORT void
gluSphere(GLUquadric *q, GLdouble radius, GLint slices, GLint stacks)
{
    if (!q || slices < 2 || stacks < 2 || radius < 0)
        return;
    if (q->drawStyle == GLU_POINT || q->drawStyle == GLU_LINE || q->drawStyle == GLU_SILHOUETTE) {
        if (q->drawStyle == GLU_POINT)
            glBegin(GL_POINTS);
        for (int j = 1; j < stacks; j++) {
            double rho = M_PI * j / stacks;
            if (q->drawStyle != GLU_POINT)
                glBegin(GL_LINE_LOOP);
            for (int i = 0; i < slices; i++) {
                double th = 2 * M_PI * i / slices;
                double x = -sin(th) * sin(rho), y = cos(th) * sin(rho), z = cos(rho);
                normal3(q, x, y, z);
                glVertex3d(x * radius, y * radius, z * radius);
            }
            if (q->drawStyle != GLU_POINT)
                glEnd();
        }
        if (q->drawStyle != GLU_POINT)
            for (int i = 0; i < slices; i++) {
                double th = 2 * M_PI * i / slices;
                glBegin(GL_LINE_STRIP);
                for (int j = 0; j <= stacks; j++) {
                    double rho = M_PI * j / stacks;
                    double x = -sin(th) * sin(rho), y = cos(th) * sin(rho), z = cos(rho);
                    normal3(q, x, y, z);
                    glVertex3d(x * radius, y * radius, z * radius);
                }
                glEnd();
            }
        if (q->drawStyle == GLU_POINT)
            glEnd();
        return;
    }
    for (int j = 0; j < stacks; j++) {
        double rho0 = M_PI * j / stacks, rho1 = M_PI * (j + 1) / stacks;
        glBegin(GL_QUAD_STRIP);
        for (int i = 0; i <= slices; i++) {
            double th = 2 * M_PI * (i == slices ? 0 : i) / slices;
            double s = 1 - (double)i / slices;
            double x0 = -sin(th) * sin(rho0), y0 = cos(th) * sin(rho0), z0 = cos(rho0);
            double x1 = -sin(th) * sin(rho1), y1 = cos(th) * sin(rho1), z1 = cos(rho1);
            if (q->orientation == GLU_INSIDE) {
                normal3(q, x1, y1, z1);
                texcoord(q, s, 1 - (double)(j + 1) / stacks);
                glVertex3d(x1 * radius, y1 * radius, z1 * radius);
                normal3(q, x0, y0, z0);
                texcoord(q, s, 1 - (double)j / stacks);
                glVertex3d(x0 * radius, y0 * radius, z0 * radius);
            } else {
                normal3(q, x0, y0, z0);
                texcoord(q, s, 1 - (double)j / stacks);
                glVertex3d(x0 * radius, y0 * radius, z0 * radius);
                normal3(q, x1, y1, z1);
                texcoord(q, s, 1 - (double)(j + 1) / stacks);
                glVertex3d(x1 * radius, y1 * radius, z1 * radius);
            }
        }
        glEnd();
    }
}

#pragma mark - Images

static int
components(GLenum format)
{
    switch (format) {
    case GL_RGBA:
    case GL_BGRA: return 4;
    case GL_RGB:
    case GL_BGR: return 3;
    case GL_LUMINANCE_ALPHA: return 2;
    case GL_RED:
    case GL_GREEN:
    case GL_BLUE:
    case GL_ALPHA:
    case GL_LUMINANCE:
    case GL_INTENSITY: return 1;
    default: return 0;
    }
}

/* Box-filtered scaling of 8-bit (or float) images. */
FINCH_EXPORT GLint
gluScaleImage(GLenum format, GLsizei wIn, GLsizei hIn, GLenum typeIn, const void *dataIn, GLsizei wOut, GLsizei hOut, GLenum typeOut,
              GLvoid *dataOut)
{
    int n = components(format);
    if (!n)
        return GLU_INVALID_ENUM;
    if ((typeIn != GL_UNSIGNED_BYTE && typeIn != GL_FLOAT) || typeIn != typeOut)
        return GLU_INVALID_ENUM;
    if (wIn <= 0 || hIn <= 0 || wOut <= 0 || hOut <= 0)
        return GLU_INVALID_VALUE;
    bool fl = typeIn == GL_FLOAT;
    for (int y = 0; y < hOut; y++) {
        double sy0 = (double)y * hIn / hOut, sy1 = (double)(y + 1) * hIn / hOut;
        for (int x = 0; x < wOut; x++) {
            double sx0 = (double)x * wIn / wOut, sx1 = (double)(x + 1) * wIn / wOut;
            double acc[4] = {0}, area = 0;
            for (int yy = (int)sy0; yy < (int)ceil(sy1) && yy < hIn; yy++)
                for (int xx = (int)sx0; xx < (int)ceil(sx1) && xx < wIn; xx++) {
                    double wy = fmin(yy + 1, sy1) - fmax(yy, sy0), wx = fmin(xx + 1, sx1) - fmax(xx, sx0);
                    double w = wx * wy;
                    for (int c = 0; c < n; c++) {
                        size_t i = ((size_t)yy * wIn + xx) * n + c;
                        acc[c] += w * (fl ? ((const float *)dataIn)[i] : ((const uint8_t *)dataIn)[i]);
                    }
                    area += w;
                }
            for (int c = 0; c < n; c++) {
                size_t o = ((size_t)y * wOut + x) * n + c;
                double v = area > 0 ? acc[c] / area : 0;
                if (fl)
                    ((float *)dataOut)[o] = (float)v;
                else
                    ((uint8_t *)dataOut)[o] = (uint8_t)lround(fmin(255, fmax(0, v)));
            }
        }
    }
    return 0;
}

FINCH_EXPORT GLint
gluBuild2DMipmaps(GLenum target, GLint internalFormat, GLsizei width, GLsizei height, GLenum format, GLenum type, const void *data)
{
    int n = components(format);
    if (!n)
        return GLU_INVALID_ENUM;
    if (width <= 0 || height <= 0)
        return GLU_INVALID_VALUE;
    size_t bytes = type == GL_FLOAT ? 4 : 1;
    GLint maxSize = 0;
    glGetIntegerv(GL_MAX_TEXTURE_SIZE, &maxSize);
    GLsizei w = 1, h = 1;
    while (w * 2 <= width && w * 2 <= maxSize)
        w *= 2;
    while (h * 2 <= height && h * 2 <= maxSize)
        h *= 2;
    void *level = malloc((size_t)w * h * n * bytes);
    if (!level)
        return GLU_OUT_OF_MEMORY;
    GLint err = gluScaleImage(format, width, height, type, data, w, h, type, level);
    if (err) {
        free(level);
        return err;
    }
    glPixelStorei(GL_UNPACK_ALIGNMENT, 1);
    for (GLint l = 0;; l++) {
        glTexImage2D(target, l, internalFormat, w, h, 0, format, type, level);
        if (w == 1 && h == 1)
            break;
        GLsizei nw = w > 1 ? w / 2 : 1, nh = h > 1 ? h / 2 : 1;
        void *next = malloc((size_t)nw * nh * n * bytes);
        if (!next)
            break;
        gluScaleImage(format, w, h, type, level, nw, nh, type, next);
        free(level);
        level = next;
        w = nw, h = nh;
    }
    free(level);
    return 0;
}

FINCH_EXPORT GLint
gluBuild1DMipmaps(GLenum target, GLint internalFormat, GLsizei width, GLenum format, GLenum type, const void *data)
{
    int n = components(format);
    if (!n)
        return GLU_INVALID_ENUM;
    if (width <= 0)
        return GLU_INVALID_VALUE;
    size_t bytes = type == GL_FLOAT ? 4 : 1;
    GLsizei w = 1;
    while (w * 2 <= width)
        w *= 2;
    void *level = malloc((size_t)w * n * bytes);
    if (!level)
        return GLU_OUT_OF_MEMORY;
    gluScaleImage(format, width, 1, type, data, w, 1, type, level);
    glPixelStorei(GL_UNPACK_ALIGNMENT, 1);
    for (GLint l = 0;; l++) {
        glTexImage1D(target, l, internalFormat, w, 0, format, type, level);
        if (w == 1)
            break;
        GLsizei nw = w / 2;
        void *next = malloc((size_t)nw * n * bytes);
        if (!next)
            break;
        gluScaleImage(format, w, 1, type, level, nw, 1, type, next);
        free(level);
        level = next;
        w = nw;
    }
    free(level);
    return 0;
}

#pragma mark - Strings

FINCH_EXPORT const GLubyte *
gluErrorString(GLenum error)
{
    switch (error) {
    case GL_NO_ERROR: return (const GLubyte *)"no error";
    case GL_INVALID_ENUM: return (const GLubyte *)"invalid enumerant";
    case GL_INVALID_VALUE: return (const GLubyte *)"invalid value";
    case GL_INVALID_OPERATION: return (const GLubyte *)"invalid operation";
    case GL_STACK_OVERFLOW: return (const GLubyte *)"stack overflow";
    case GL_STACK_UNDERFLOW: return (const GLubyte *)"stack underflow";
    case GL_OUT_OF_MEMORY: return (const GLubyte *)"out of memory";
    case GL_INVALID_FRAMEBUFFER_OPERATION: return (const GLubyte *)"invalid framebuffer operation";
    case GLU_INVALID_ENUM: return (const GLubyte *)"invalid enumerant";
    case GLU_INVALID_VALUE: return (const GLubyte *)"invalid value";
    case GLU_OUT_OF_MEMORY: return (const GLubyte *)"out of memory";
    case GLU_INVALID_OPERATION: return (const GLubyte *)"invalid operation";
    default: return NULL;
    }
}

FINCH_EXPORT const GLubyte *
gluGetString(GLenum name)
{
    switch (name) {
    case GLU_VERSION: return (const GLubyte *)"1.3 Finch";
    case GLU_EXTENSIONS: return (const GLubyte *)"GLU_EXT_object_space_tess GLU_EXT_nurbs_tessellator";
    default: return NULL;
    }
}

FINCH_EXPORT GLboolean
gluCheckExtension(const GLubyte *extName, const GLubyte *extString)
{
    if (!extName || !extString)
        return GL_FALSE;
    size_t n = strlen((const char *)extName);
    const char *p = (const char *)extString;
    while ((p = strstr(p, (const char *)extName))) {
        if ((p == (const char *)extString || p[-1] == ' ') && (p[n] == ' ' || p[n] == 0))
            return GL_TRUE;
        p += n;
    }
    return GL_FALSE;
}
