/* SPDX-License-Identifier: MIT OR Apache-2.0 */
/*
 * OpenGL through CGL, off-screen: a pixel format and renderer description, a context
 * drawing into the app's memory (CGLSetOffScreen), the version strings' shape, clears,
 * flat and smooth-shaded geometry, depth testing, a display list, GLU's projection and
 * quadrics, lighting, selection-mode picking with names, glReadPixels and errors. Pixels
 * are sampled inside shapes (edges are the renderer's business). Compared with Apple's.
 */
#include <OpenGL/OpenGL.h>
#include <OpenGL/gl.h>
#include <OpenGL/glu.h>
#include <math.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

enum { W = 64, H = 48 };
static uint8_t pixels[W * H * 4];

/* The colour at (x, y) from the bottom left, as GL reads it back, in steps of 16. */
static void
sample(const char *label, int x, int y)
{
    uint8_t p[4] = {0};
    glReadPixels(x, y, 1, 1, GL_RGBA, GL_UNSIGNED_BYTE, p);
    printf("  %s (%d,%d): %d %d %d %d\n", label, x, y, (p[0] + 8) / 16, (p[1] + 8) / 16, (p[2] + 8) / 16, (p[3] + 8) / 16);
}

int
main(void)
{
    CGLPixelFormatAttribute attrs[] = {kCGLPFAColorSize, 24, kCGLPFAAlphaSize, 8, kCGLPFADepthSize, 24, kCGLPFAStencilSize, 8, 0};
    CGLPixelFormatObj pix = NULL;
    GLint npix = 0;
    CGLError e = CGLChoosePixelFormat(attrs, &pix, &npix);
    /* (Apple's lists its GPU and its software renderer; Finch has the software one) */
    printf("choose: error %d formats %d\n", e, npix >= 1);
    GLint depth = 0, stencil = 0, dbl = -1, alpha = 0;
    CGLDescribePixelFormat(pix, 0, kCGLPFADepthSize, &depth);
    CGLDescribePixelFormat(pix, 0, kCGLPFAStencilSize, &stencil);
    CGLDescribePixelFormat(pix, 0, kCGLPFADoubleBuffer, &dbl);
    CGLDescribePixelFormat(pix, 0, kCGLPFAAlphaSize, &alpha);
    printf("format: depth >= 24 %d stencil >= 8 %d double %d alpha %d\n", depth >= 24, stencil >= 8, dbl, alpha);
    CGLContextObj ctx = NULL;
    e = CGLCreateContext(pix, NULL, &ctx);
    printf("context: error %d retain %u format same %d\n", e, CGLGetContextRetainCount(ctx), CGLGetPixelFormat(ctx) == pix);
    GLint order = 9, opacity = 9;
    CGLError oe = CGLGetParameter(ctx, kCGLCPSurfaceOrder, &order);
    CGLError pe = CGLGetParameter(ctx, kCGLCPSurfaceOpacity, &opacity);
    printf("surface order %d (error %d), opacity %d (error %d)\n", order, oe, opacity, pe);
    printf("current before %p\n", (void *)CGLGetCurrentContext());
    CGLSetCurrentContext(ctx);
    printf("current is it %d\n", CGLGetCurrentContext() == ctx);

    /* an FBO-free off-screen target: a framebuffer object the app makes */
    GLuint fbo = 0, color = 0, depthRB = 0;
    glGenFramebuffersEXT(1, &fbo);
    glBindFramebufferEXT(GL_FRAMEBUFFER_EXT, fbo);
    glGenRenderbuffersEXT(1, &color);
    glBindRenderbufferEXT(GL_RENDERBUFFER_EXT, color);
    glRenderbufferStorageEXT(GL_RENDERBUFFER_EXT, GL_RGBA8, W, H);
    glFramebufferRenderbufferEXT(GL_FRAMEBUFFER_EXT, GL_COLOR_ATTACHMENT0_EXT, GL_RENDERBUFFER_EXT, color);
    glGenRenderbuffersEXT(1, &depthRB);
    glBindRenderbufferEXT(GL_RENDERBUFFER_EXT, depthRB);
    glRenderbufferStorageEXT(GL_RENDERBUFFER_EXT, GL_DEPTH_COMPONENT24, W, H);
    glFramebufferRenderbufferEXT(GL_FRAMEBUFFER_EXT, GL_DEPTH_ATTACHMENT_EXT, GL_RENDERBUFFER_EXT, depthRB);
    printf("framebuffer complete %d\n", glCheckFramebufferStatusEXT(GL_FRAMEBUFFER_EXT) == GL_FRAMEBUFFER_COMPLETE_EXT);
    glViewport(0, 0, W, H);
    const char *version = (const char *)glGetString(GL_VERSION);
    printf("version starts with a digit %d, renderer named %d, extensions have FBOs %d\n", version && version[0] >= '1' && version[0] <= '9',
        glGetString(GL_RENDERER) != NULL, strstr((const char *)glGetString(GL_EXTENSIONS), "GL_EXT_framebuffer_object") != NULL);

    /* clears */
    glClearColor(0.25f, 0.5f, 0.75f, 1);
    glClear(GL_COLOR_BUFFER_BIT | GL_DEPTH_BUFFER_BIT);
    printf("cleared:\n");
    sample("corner", 0, 0);
    sample("middle", 32, 24);

    /* flat geometry, orthographic */
    glMatrixMode(GL_PROJECTION);
    glLoadIdentity();
    gluOrtho2D(0, W, 0, H);
    glMatrixMode(GL_MODELVIEW);
    glLoadIdentity();
    glColor3f(1, 0, 0);
    glRectf(4, 4, 28, 20);
    glBegin(GL_TRIANGLES);
    glColor3f(0, 1, 0);
    glVertex2f(36, 4);
    glVertex2f(60, 4);
    glVertex2f(48, 28);
    glEnd();
    printf("rect and triangle:\n");
    sample("rect", 16, 12);
    sample("triangle", 48, 10);
    sample("between", 32, 12);

    /* smooth shading across a quad: a pixel in its middle is the mean */
    glClear(GL_COLOR_BUFFER_BIT);
    glShadeModel(GL_SMOOTH);
    glBegin(GL_QUADS);
    glColor3f(0, 0, 0);
    glVertex2f(0, 0);
    glColor3f(1, 1, 1);
    glVertex2f(W, 0);
    glColor3f(1, 1, 1);
    glVertex2f(W, H);
    glColor3f(0, 0, 0);
    glVertex2f(0, H);
    glEnd();
    printf("gradient:\n");
    sample("left", 2, 24);
    sample("middle", 32, 24);
    sample("right", 61, 24);

    /* depth: a nearer blue square over a farther red one, drawn first */
    glClear(GL_COLOR_BUFFER_BIT | GL_DEPTH_BUFFER_BIT);
    glEnable(GL_DEPTH_TEST);
    glMatrixMode(GL_PROJECTION);
    glLoadIdentity();
    glOrtho(0, W, 0, H, -10, 10);
    glMatrixMode(GL_MODELVIEW);
    glColor3f(0, 0, 1);
    glBegin(GL_QUADS);
    glVertex3f(10, 10, 5), glVertex3f(40, 10, 5), glVertex3f(40, 40, 5), glVertex3f(10, 40, 5);
    glEnd();
    glColor3f(1, 0, 0);
    glBegin(GL_QUADS);
    glVertex3f(20, 20, -5), glVertex3f(50, 20, -5), glVertex3f(50, 46, -5), glVertex3f(20, 46, -5);
    glEnd();
    printf("depth:\n");
    sample("both", 30, 30);
    sample("red only", 45, 43);
    glDisable(GL_DEPTH_TEST);

    /* a display list */
    GLuint list = glGenLists(1);
    glNewList(list, GL_COMPILE);
    glColor3f(1, 1, 0);
    glRectf(0, 0, 8, 8);
    glEndList();
    glClear(GL_COLOR_BUFFER_BIT);
    glLoadIdentity();
    glTranslatef(20, 20, 0);
    glCallList(list);
    printf("display list %u is list %d:\n", list > 0, glIsList(list));
    sample("inside", 24, 24);
    sample("outside", 4, 4);
    glDeleteLists(list, 1);

    /* GLU: a lit sphere in perspective */
    glClearColor(0, 0, 0, 1);
    glClear(GL_COLOR_BUFFER_BIT | GL_DEPTH_BUFFER_BIT);
    glEnable(GL_DEPTH_TEST);
    glMatrixMode(GL_PROJECTION);
    glLoadIdentity();
    gluPerspective(45, (double)W / H, 1, 20);
    glMatrixMode(GL_MODELVIEW);
    glLoadIdentity();
    gluLookAt(0, 0, 5, 0, 0, 0, 0, 1, 0);
    glEnable(GL_LIGHTING);
    glEnable(GL_LIGHT0);
    GLfloat pos[] = {0, 0, 10, 1}, white[] = {1, 1, 1, 1}, red[] = {1, 0, 0, 1};
    glLightfv(GL_LIGHT0, GL_POSITION, pos);
    glLightfv(GL_LIGHT0, GL_DIFFUSE, white);
    glMaterialfv(GL_FRONT, GL_DIFFUSE, red);
    GLUquadric *q = gluNewQuadric();
    gluQuadricNormals(q, GLU_SMOOTH);
    gluSphere(q, 1, 32, 16);
    printf("lit sphere:\n");
    sample("centre", 32, 24);
    sample("background", 2, 2);
    glDisable(GL_LIGHTING);
    GLdouble model[16], proj[16];
    GLint view[4];
    glGetDoublev(GL_MODELVIEW_MATRIX, model);
    glGetDoublev(GL_PROJECTION_MATRIX, proj);
    glGetIntegerv(GL_VIEWPORT, view);
    GLdouble wx, wy, wz, ox, oy, oz;
    gluProject(1, 0, 0, model, proj, view, &wx, &wy, &wz);
    gluUnProject(wx, wy, wz, model, proj, view, &ox, &oy, &oz);
    printf("project (1,0,0): %.2f %.2f %.4f; back %.3f %.3f %.3f\n", wx, wy, wz, ox, fabs(oy) < 1e-6 ? 0 : oy, fabs(oz) < 1e-6 ? 0 : oz);
    gluDeleteQuadric(q);

    /* picking: two named squares, a pick region over the second */
    GLuint hits[64];
    glSelectBuffer(64, hits);
    glRenderMode(GL_SELECT);
    glInitNames();
    glPushName(0);
    glMatrixMode(GL_PROJECTION);
    glLoadIdentity();
    gluPickMatrix(45, 24, 4, 4, view);
    gluOrtho2D(0, W, 0, H);
    glMatrixMode(GL_MODELVIEW);
    glLoadIdentity();
    glLoadName(1);
    glRectf(4, 4, 20, 44);
    glLoadName(2);
    glRectf(36, 4, 60, 44);
    GLint n = glRenderMode(GL_RENDER);
    printf("picking: %d hit(s)", n);
    for (GLint i = 0, at = 0; i < n && at < 64; i++) {
        GLuint names = hits[at];
        printf(" [names %u:", names);
        for (GLuint k = 0; k < names; k++)
            printf(" %u", hits[at + 3 + k]);
        printf("]");
        at += 3 + names;
    }
    printf("\n");

    /* errors */
    while (glGetError() != GL_NO_ERROR)
        ;
    glEnable(0x1234);
    printf("bad enum error %#x, then %#x\n", glGetError(), glGetError());
    printf("glu errors: %s / %s\n", gluErrorString(GL_INVALID_ENUM), gluErrorString(GLU_OUT_OF_MEMORY));

    /* drawing into the app's memory: refused, as on Apple silicon */
    glBindFramebufferEXT(GL_FRAMEBUFFER_EXT, 0);
    e = CGLSetOffScreen(ctx, W, H, W * 4, pixels);
    printf("off screen: error %d\n", e);

    CGLSetCurrentContext(NULL);
    printf("current after clear %p\n", (void *)CGLGetCurrentContext());
    CGLDestroyContext(ctx);
    CGLDestroyPixelFormat(pix);
    GLint major = 0, minor = 0;
    CGLGetVersion(&major, &minor);
    printf("CGL version %d.%d, error string %s\n", major, minor, CGLErrorString(kCGLBadContext));
    return 0;
}
