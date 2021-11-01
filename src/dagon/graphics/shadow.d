/*
Copyright (c) 2017-2018 Timur Gafarov

Boost Software License - Version 1.0 - August 17th, 2003
Permission is hereby granted, free of charge, to any person or organization
obtaining a copy of the software and accompanying documentation covered by
this license (the "Software") to use, reproduce, display, distribute,
execute, and transmit the Software, and to prepare derivative works of the
Software, and to permit third-parties to whom the Software is furnished to
do so, all subject to the following:

The copyright notices in the Software and this entire statement, including
the above license grant, this restriction and the following disclaimer,
must be included in all copies of the Software, in whole or in part, and
all derivative works of the Software, unless such copies or derivative
works are solely in the form of machine-executable object code generated by
a source language processor.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
FITNESS FOR A PARTICULAR PURPOSE, TITLE AND NON-INFRINGEMENT. IN NO EVENT
SHALL THE COPYRIGHT HOLDERS OR ANYONE DISTRIBUTING THE SOFTWARE BE LIABLE
FOR ANY DAMAGES OR OTHER LIABILITY, WHETHER IN CONTRACT, TORT OR OTHERWISE,
ARISING FROM, OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER
DEALINGS IN THE SOFTWARE.
*/

module dagon.graphics.shadow;

import std.stdio;
import std.math;
import std.conv;

import dlib.core.memory;
import dlib.math.vector;
import dlib.math.matrix;
import dlib.math.transformation;
import dlib.math.interpolation;
import dlib.image.color;
import dlib.image.unmanaged;
import dlib.image.render.shapes;

import derelict.opengl;

import dagon.core.interfaces;
import dagon.core.ownership;
import dagon.logics.entity;
import dagon.logics.behaviour;
import dagon.graphics.shapes;
import dagon.graphics.texture;
import dagon.graphics.view;
import dagon.graphics.rc;
import dagon.graphics.environment;
import dagon.graphics.material;
import dagon.graphics.materials.generic;
import dagon.resource.scene;

class ShadowArea: Owner
{
    Environment environment;
    Matrix4x4f biasMatrix;
    Matrix4x4f projectionMatrix;
    Matrix4x4f viewMatrix;
    Matrix4x4f invViewMatrix;
    Matrix4x4f shadowMatrix;
    float width;
    float height;
    float depth;
    float start;
    float end;
    float scale = 1.0f;
    Vector3f position;

    this(Environment env, float w, float h, float start, float end, Owner o)
    {
        super(o);
        this.width = w;
        this.height = h;
        this.start = start;
        this.end = end;
        this.environment = env;

        depth = abs(start) + abs(end);

        this.position = Vector3f(0, 0, 0);

        this.biasMatrix = matrixf(
            0.5f, 0.0f, 0.0f, 0.5f,
            0.0f, 0.5f, 0.0f, 0.5f,
            0.0f, 0.0f, 0.5f, 0.5f,
            0.0f, 0.0f, 0.0f, 1.0f,
        );

        float hw = w * 0.5f;
        float hh = h * 0.5f;
        this.projectionMatrix = orthoMatrix(-hw, hw, -hh, hh, start, end);

        this.shadowMatrix = Matrix4x4f.identity;
        this.viewMatrix = Matrix4x4f.identity;
        this.invViewMatrix = Matrix4x4f.identity;
    }

    void update(RenderingContext* rc, double dt)
    {
        auto t = translationMatrix(position);
        auto r = environment.sunRotation.toMatrix4x4;
        invViewMatrix = t * r;
        viewMatrix = invViewMatrix.inverse;
        shadowMatrix = scaleMatrix(Vector3f(scale, scale, 1.0f)) * biasMatrix * projectionMatrix * viewMatrix * rc.invViewMatrix; // view.invViewMatrix;
    }
}

class ShadowBackend: GLSLMaterialBackend
{

    string vsText =
    "
        #version 330 core

        uniform mat4 modelViewMatrix;
        uniform mat4 projectionMatrix;

        layout (location = 0) in vec3 va_Vertex;
        layout (location = 2) in vec2 va_Texcoord;

        out vec2 texCoord;

        void main()
        {
            texCoord = va_Texcoord;
            gl_Position = projectionMatrix * modelViewMatrix * vec4(va_Vertex, 1.0);
        }
    ";

    string fsText =
    "
        #version 330 core

        in vec2 texCoord;
        uniform sampler2D diffuseTexture;
        out vec4 frag_color;

        void main()
        {
            vec4 diffuseColor = texture(diffuseTexture, texCoord);
            if (diffuseColor.a == 0)
                discard;
            frag_color = vec4(1.0, 1.0, 1.0, 1.0);
        }
    ";

    override string vertexShaderSrc() {return vsText;}
    override string fragmentShaderSrc() {return fsText;}

    GLint modelViewMatrixLoc;
    GLint projectionMatrixLoc;

    GLint diffuseTextureLoc;

    this(Owner o)
    {
        super(o);

        modelViewMatrixLoc = glGetUniformLocation(shaderProgram, "modelViewMatrix");
        projectionMatrixLoc = glGetUniformLocation(shaderProgram, "projectionMatrix");
        diffuseTextureLoc = glGetUniformLocation(shaderProgram, "diffuseTexture");
    }


    final void setModelViewMatrix(Matrix4x4f modelViewMatrix){
        glUniformMatrix4fv(modelViewMatrixLoc, 1, GL_FALSE, modelViewMatrix.arrayof.ptr);
    }
    final void setAlpha(float alpha){ }
    final void setInformation(Vector4f information){ }

    override void bind(GenericMaterial mat, RenderingContext* rc)
    {
        auto idiffuse = "diffuse" in mat.inputs;
        glDisable(GL_CULL_FACE);

        glUseProgram(shaderProgram);

        glUniformMatrix4fv(modelViewMatrixLoc, 1, GL_FALSE, rc.modelViewMatrix.arrayof.ptr);
        glUniformMatrix4fv(projectionMatrixLoc, 1, GL_FALSE, rc.projectionMatrix.arrayof.ptr);

        if (idiffuse.texture is null)
        {
            Color4f color = Color4f(idiffuse.asVector4f);
            idiffuse.texture = makeOnePixelTexture(mat, color);
        }
        glActiveTexture(GL_TEXTURE0);
        idiffuse.texture.bind();
        glUniform1i(diffuseTextureLoc, 0);
    }

    override void unbind(GenericMaterial mat, RenderingContext* rc)
    {
        auto idiffuse = "diffuse" in mat.inputs;
        assert(!!idiffuse.texture);
        glActiveTexture(GL_TEXTURE0);
        idiffuse.texture.unbind();

        glUseProgram(0);
    }
}

class BoneShadowBackend: GLSLMaterialBackend
{

    string vsText =
    "
        #version 450 core

        uniform mat4 modelViewMatrix;
        uniform mat4 projectionMatrix;

        uniform float bulk = 1.0f;

        layout (location = 0) in vec3 va_Vertex0;
        layout (location = 1) in vec3 va_Vertex1;
        layout (location = 2) in vec3 va_Vertex2;
        layout (location = 4) in vec2 va_Texcoord;
        layout (location = 5) in uvec3 va_BoneIndices;
        layout (location = 6) in vec3 va_Weights;
        layout (location = 7) uniform mat4 pose[32];

        out vec2 texCoord;

        void main()
        {
            texCoord = va_Texcoord;
            vec4 newVertex = pose[va_BoneIndices.x] * vec4(bulk*va_Vertex0, 1.0) * va_Weights.x
                           + pose[va_BoneIndices.y] * vec4(bulk*va_Vertex1, 1.0) * va_Weights.y
                           + pose[va_BoneIndices.z] * vec4(bulk*va_Vertex2, 1.0) * va_Weights.z;
            gl_Position = projectionMatrix * modelViewMatrix * vec4(newVertex.xyz, 1.0);
        }
    ";

    string fsText =
    "
        #version 330 core

        in vec2 texCoord;
        uniform sampler2D diffuseTexture;
        out vec4 frag_color;

        void main()
        {
            vec4 diffuseColor = texture(diffuseTexture, texCoord);
            if (diffuseColor.a == 0)
                discard;
            frag_color = vec4(1.0, 1.0, 1.0, 1.0);
        }
    ";

    override string vertexShaderSrc() {return vsText;}
    override string fragmentShaderSrc() {return fsText;}

    GLint modelViewMatrixLoc;
    GLint projectionMatrixLoc;

    GLint bulkLoc;

    GLint diffuseTextureLoc;

    this(Owner o)
    {
        super(o);

        modelViewMatrixLoc = glGetUniformLocation(shaderProgram, "modelViewMatrix");
        projectionMatrixLoc = glGetUniformLocation(shaderProgram, "projectionMatrix");
        bulkLoc = glGetUniformLocation(shaderProgram, "bulk");
        diffuseTextureLoc = glGetUniformLocation(shaderProgram, "diffuseTexture");
    }

    final void setModelViewMatrix(Matrix4x4f modelViewMatrix){
        glUniformMatrix4fv(modelViewMatrixLoc, 1, GL_FALSE, modelViewMatrix.arrayof.ptr);
    }
    final void setAlpha(float alpha){ }
    final void setInformation(Vector4f information){ }
    final void setBulk(float bulk){
        glUniform1f(bulkLoc, bulk);
    }

    override void bind(GenericMaterial mat, RenderingContext* rc)
    {
        auto idiffuse = "diffuse" in mat.inputs;
        glDisable(GL_CULL_FACE);

        glUseProgram(shaderProgram);

        glUniformMatrix4fv(modelViewMatrixLoc, 1, GL_FALSE, rc.modelViewMatrix.arrayof.ptr);
        glUniformMatrix4fv(projectionMatrixLoc, 1, GL_FALSE, rc.projectionMatrix.arrayof.ptr);

        if (idiffuse.texture is null)
        {
            Color4f color = Color4f(idiffuse.asVector4f);
            idiffuse.texture = makeOnePixelTexture(mat, color);
        }
        glActiveTexture(GL_TEXTURE0);
        idiffuse.texture.bind();
        glUniform1i(diffuseTextureLoc, 0);
    }

    override void unbind(GenericMaterial mat, RenderingContext* rc)
    {
        auto idiffuse = "diffuse" in mat.inputs;
        assert(!!idiffuse.texture);

        glActiveTexture(GL_TEXTURE0);
        idiffuse.texture.unbind();

        glUseProgram(0);
    }
}


class CascadedShadowMap: Owner
{
    uint size;
    Scene scene;
    ShadowArea[3] area;

    GLuint depthTexture;
    GLuint[3] framebuffer;

    ShadowBackend sb;
    GenericMaterial sm;
    BoneShadowBackend bsb;
    GenericMaterial bsm;

    float[3] projSize = [5.0f,15.0f,400.0f];

    float zStart = -300.0f;
    float zEnd = 300.0f;

    Color4f shadowColor = Color4f(1.0f, 1.0f, 1.0f, 1.0f);
    float shadowBrightness = 0.1f;
    bool useHeightCorrectedShadows = false;

    this(uint size, Scene scene, float[3] projSize, float zStart, float zEnd, Owner o)
    {
        super(o);
        this.size = size;
        this.scene = scene;

        this.projSize = projSize;

        this.zStart = zStart;
        this.zEnd = zEnd;

        foreach(i;0..this.area.length)
            this.area[i] = New!ShadowArea(scene.environment, projSize[i], projSize[i], zStart, zEnd, this);

        this.sb = New!ShadowBackend(this);
        this.sm = New!GenericMaterial(sb, this);

        this.bsb = New!BoneShadowBackend(this);
        this.bsm = New!GenericMaterial(bsb, this);

        glGenTextures(1, &depthTexture);
        glActiveTexture(GL_TEXTURE0);
        glBindTexture(GL_TEXTURE_2D_ARRAY, depthTexture);
        glTexParameteri(GL_TEXTURE_2D_ARRAY, GL_TEXTURE_MIN_FILTER, GL_LINEAR);
        glTexParameteri(GL_TEXTURE_2D_ARRAY, GL_TEXTURE_MAG_FILTER, GL_LINEAR);
        glTexParameteri(GL_TEXTURE_2D_ARRAY, GL_TEXTURE_WRAP_S, GL_CLAMP_TO_BORDER);
        glTexParameteri(GL_TEXTURE_2D_ARRAY, GL_TEXTURE_WRAP_T, GL_CLAMP_TO_BORDER);

        Color4f borderColor = Color4f(1, 1, 1, 1);

        glTexParameterfv(GL_TEXTURE_2D_ARRAY, GL_TEXTURE_BORDER_COLOR, borderColor.arrayof.ptr);
        glTexParameteri(GL_TEXTURE_2D_ARRAY, GL_TEXTURE_COMPARE_MODE, GL_COMPARE_REF_TO_TEXTURE);
        glTexParameteri(GL_TEXTURE_2D_ARRAY, GL_TEXTURE_COMPARE_FUNC, GL_LEQUAL);

        glTexImage3D(GL_TEXTURE_2D_ARRAY, 0, GL_DEPTH_COMPONENT24, size, size, 3, 0, GL_DEPTH_COMPONENT, GL_FLOAT, null);

        glTexParameteri(GL_TEXTURE_2D_ARRAY, GL_TEXTURE_BASE_LEVEL, 0);
        glTexParameteri(GL_TEXTURE_2D_ARRAY, GL_TEXTURE_MAX_LEVEL, 0);

        glBindTexture(GL_TEXTURE_2D_ARRAY, 0);

        foreach(GLint i;0..framebuffer.length){
            glGenFramebuffers(1, &framebuffer[i]);
            glBindFramebuffer(GL_FRAMEBUFFER, framebuffer[i]);
            glDrawBuffer(GL_NONE);
            glReadBuffer(GL_NONE);
            glFramebufferTextureLayer(GL_FRAMEBUFFER, GL_DEPTH_ATTACHMENT, depthTexture, 0, i);
            glBindFramebuffer(GL_FRAMEBUFFER, 0);
        }
    }

    Vector3f position()
    {
        return area[0].position;
    }

    void position(Vector3f pos)
    {
        foreach(i;0..area.length)
            area[i].position = pos;
    }

    ~this()
    {
        glBindFramebuffer(GL_FRAMEBUFFER, 0);
        foreach(i;0..framebuffer.length)
            glDeleteFramebuffers(1, &framebuffer[i]);

        if (glIsTexture(depthTexture))
            glDeleteTextures(1, &depthTexture);
    }

    void update(RenderingContext* rc, double dt)
    {
        foreach(i;0..area.length)
            area[i].update(rc, dt);
    }

    void render(RenderingContext* rc)
    {
        auto rcLocal = *rc;
        rcLocal.shadowMode = true;
        foreach(i;0..area.length){
            glBindFramebuffer(GL_FRAMEBUFFER, framebuffer[i]);

            glViewport(0, 0, size, size);
            glScissor(0, 0, size, size);
            glClear(GL_DEPTH_BUFFER_BIT);

            glEnable(GL_DEPTH_TEST);

            rcLocal.projectionMatrix = area[i].projectionMatrix;
            rcLocal.viewMatrix = area[i].viewMatrix;
            rcLocal.invViewMatrix = area[i].invViewMatrix;
            rcLocal.normalMatrix = rcLocal.invViewMatrix.transposed;
            rcLocal.viewRotationMatrix = matrix3x3to4x4(matrix4x4to3x3(rcLocal.viewMatrix));
            rcLocal.invViewRotationMatrix = matrix3x3to4x4(matrix4x4to3x3(rcLocal.invViewMatrix));

            glPolygonOffset(3.0, 0.0);
            glDisable(GL_CULL_FACE);
            glColorMask(GL_FALSE, GL_FALSE, GL_FALSE, GL_FALSE);

            scene.renderShadowCastingEntities3D(&rcLocal);
            scene.particleSystem.render(&rcLocal);
        }

        glColorMask(GL_TRUE, GL_TRUE, GL_TRUE, GL_TRUE);
        glEnable(GL_CULL_FACE);
        glPolygonOffset(0.0, 0.0);

        glBindFramebuffer(GL_FRAMEBUFFER, 0);
    }
}
