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

module dagon.ui.ftfont;

import std.stdio;

import std.string;
import std.ascii;
import std.utf;
import std.file;

import dlib.core.memory;
import dlib.core.stream;
import dlib.container.dict;
import dlib.text.utf8;
import dlib.math.vector;
import dlib.image.color;

import derelict.opengl;
import derelict.freetype.ft;

import dagon.core.ownership;
import dagon.ui.font;
import dagon.graphics.rc;

struct Glyph
{
    bool valid;
    GLuint textureId = 0;
    FT_Glyph ftGlyph = null;
    int width = 0;
    int height = 0;
    FT_Pos advanceX = 0;
}

int nextPowerOfTwo(int a)
{
    int rval = 1;
    while(rval < a)
        rval <<= 1;
    return rval;
}

final class FreeTypeFont: Font
{
    FT_Face ftFace;
    FT_Library ftLibrary;
    Dict!(Glyph, dchar) glyphs;

    Vector2f[4] vertices;
    Vector2f[4] texcoords;
    uint[3][2] indices;

    GLuint vao = 0;
    GLuint vbo = 0;
    GLuint tbo = 0;
    GLuint eao = 0;

    bool canRender = false;

    GLuint shaderProgram;
    GLuint vertexShader;
    GLuint fragmentShader;

    GLint modelViewMatrixLoc;
    GLint projectionMatrixLoc;

    GLint glyphPositionLoc;
    GLint glyphScaleLoc;
    GLint glyphTexcoordScaleLoc;

    GLint glyphTextureLoc;
    GLint glyphColorLoc;

    string vsText =
    "
        #version 330 core

        uniform mat4 modelViewMatrix;
        uniform mat4 projectionMatrix;

        uniform vec2 glyphPosition;
        uniform vec2 glyphScale;
        uniform vec2 glyphTexcoordScale;

        layout (location = 0) in vec2 va_Vertex;
        layout (location = 1) in vec2 va_Texcoord;

        out vec2 texCoord;

        void main()
        {
            texCoord = va_Texcoord * glyphTexcoordScale;
            gl_Position = projectionMatrix * modelViewMatrix * vec4(glyphPosition + va_Vertex * glyphScale, 0.0, 1.0);
        }
    ";

    string fsText =
    "
        #version 330 core

        uniform sampler2D glyphTexture;
        uniform vec4 glyphColor;

        in vec2 texCoord;
        out vec4 frag_color;

        void main()
        {
            vec4 t = texture(glyphTexture, texCoord);
            frag_color = vec4(t.rrr, t.g) * glyphColor;
        }
    ";

    this(uint height, Owner o)
    {
        super(o);
        this.height = height;

        if (FT_Init_FreeType(&ftLibrary))
            throw new Exception("FT_Init_FreeType failed");

        vertices[0] = Vector2f(0, 1);
        vertices[1] = Vector2f(0, 0);
        vertices[2] = Vector2f(1, 0);
        vertices[3] = Vector2f(1, 1);

        texcoords[0] = Vector2f(0, 1);
        texcoords[1] = Vector2f(0, 0);
        texcoords[2] = Vector2f(1, 0);
        texcoords[3] = Vector2f(1, 1);

        indices[0][0] = 0;
        indices[0][1] = 1;
        indices[0][2] = 2;

        indices[1][0] = 0;
        indices[1][1] = 2;
        indices[1][2] = 3;
    }

    void createFromFile(string filename)
    {
        if (!exists(filename))
            throw new Exception("Cannot find font file " ~ filename);

        if (FT_New_Face(ftLibrary, toStringz(filename), 0, &ftFace))
            throw new Exception("FT_New_Face failed (there is probably a problem with your font file)");

        FT_Set_Char_Size(ftFace, cast(int)height << 6, cast(int)height << 6, 96, 96);
        glyphs = New!(Dict!(Glyph, dchar));
    }

    void createFromMemory(ubyte[] buffer)
    {
        if (FT_New_Memory_Face(ftLibrary, buffer.ptr, cast(uint)buffer.length, 0, &ftFace))
            throw new Exception("FT_New_Face failed (there is probably a problem with your font file)");

        FT_Set_Char_Size(ftFace, cast(int)height << 6, cast(int)height << 6, 96, 96);
        glyphs = New!(Dict!(Glyph, dchar));
    }

    void prepareVAO()
    {
        if (canRender)
            return;

        glGenBuffers(1, &vbo);
        glBindBuffer(GL_ARRAY_BUFFER, vbo);
        glBufferData(GL_ARRAY_BUFFER, vertices.length * float.sizeof * 2, vertices.ptr, GL_STATIC_DRAW);

        glGenBuffers(1, &tbo);
        glBindBuffer(GL_ARRAY_BUFFER, tbo);
        glBufferData(GL_ARRAY_BUFFER, texcoords.length * float.sizeof * 2, texcoords.ptr, GL_STATIC_DRAW);

        glGenBuffers(1, &eao);
        glBindBuffer(GL_ELEMENT_ARRAY_BUFFER, eao);
        glBufferData(GL_ELEMENT_ARRAY_BUFFER, indices.length * uint.sizeof * 3, indices.ptr, GL_STATIC_DRAW);

        glGenVertexArrays(1, &vao);
        glBindVertexArray(vao);
        glBindBuffer(GL_ELEMENT_ARRAY_BUFFER, eao);

        glEnableVertexAttribArray(0);
        glBindBuffer(GL_ARRAY_BUFFER, vbo);
        glVertexAttribPointer(0, 2, GL_FLOAT, GL_FALSE, 0, null);

        glEnableVertexAttribArray(1);
        glBindBuffer(GL_ARRAY_BUFFER, tbo);
        glVertexAttribPointer(1, 2, GL_FLOAT, GL_FALSE, 0, null);

        //glBindBuffer(GL_ARRAY_BUFFER, 0);
        //glBindBuffer(GL_ELEMENT_ARRAY_BUFFER, 0);

        glBindVertexArray(0);

        const(char*)pvs = vsText.ptr;
        const(char*)pfs = fsText.ptr;

        char[1000] infobuffer = 0;
        int infobufferlen = 0;

        vertexShader = glCreateShader(GL_VERTEX_SHADER);
        glShaderSource(vertexShader, 1, &pvs, null);
        glCompileShader(vertexShader);
        GLint success = 0;
        glGetShaderiv(vertexShader, GL_COMPILE_STATUS, &success);
        if (!success)
        {
            GLint logSize = 0;
            glGetShaderiv(vertexShader, GL_INFO_LOG_LENGTH, &logSize);
            glGetShaderInfoLog(vertexShader, 999, &logSize, infobuffer.ptr);
            writeln("Error in vertex shader:");
            writeln(infobuffer[0..logSize]);
        }

        fragmentShader = glCreateShader(GL_FRAGMENT_SHADER);
        glShaderSource(fragmentShader, 1, &pfs, null);
        glCompileShader(fragmentShader);
        success = 0;
        glGetShaderiv(fragmentShader, GL_COMPILE_STATUS, &success);
        if (!success)
        {
            GLint logSize = 0;
            glGetShaderiv(fragmentShader, GL_INFO_LOG_LENGTH, &logSize);
            glGetShaderInfoLog(fragmentShader, 999, &logSize, infobuffer.ptr);
            writeln("Error in fragment shader:");
            writeln(infobuffer[0..logSize]);
        }

        shaderProgram = glCreateProgram();
        glAttachShader(shaderProgram, vertexShader);
        glAttachShader(shaderProgram, fragmentShader);
        glLinkProgram(shaderProgram);

        modelViewMatrixLoc = glGetUniformLocation(shaderProgram, "modelViewMatrix");
        projectionMatrixLoc = glGetUniformLocation(shaderProgram, "projectionMatrix");

        glyphPositionLoc = glGetUniformLocation(shaderProgram, "glyphPosition");
        glyphScaleLoc = glGetUniformLocation(shaderProgram, "glyphScale");
        glyphTexcoordScaleLoc = glGetUniformLocation(shaderProgram, "glyphTexcoordScale");
        glyphTextureLoc = glGetUniformLocation(shaderProgram, "glyphTexture");
        glyphColorLoc = glGetUniformLocation(shaderProgram, "glyphColor");

        canRender = true;
    }

    void preloadASCII()
    {
        enum ASCII_CHARS = 128;
        foreach(i; 0..ASCII_CHARS)
        {
            GLuint tex;
            glGenTextures(1, &tex);
            loadGlyph(i, tex);
        }
    }

    ~this()
    {
        if (canRender)
        {
            glDeleteVertexArrays(1, &vao);
            glDeleteBuffers(1, &vbo);
            glDeleteBuffers(1, &tbo);
            glDeleteBuffers(1, &eao);
        }

        foreach(i, glyph; glyphs)
            glDeleteTextures(1, &glyph.textureId);
        Delete(glyphs);
    }

    uint loadGlyph(dchar code, GLuint texId)
    {
        FT_Glyph glyph;

        uint charIndex = FT_Get_Char_Index(ftFace, code);

        if (charIndex == 0)
        {
            //TODO: if character wasn't found in font file
        }

        auto res = FT_Load_Glyph(ftFace, charIndex, FT_LOAD_DEFAULT);

        if (res)
            throw new Exception(format("FT_Load_Glyph failed with code %s", res));

        if (FT_Get_Glyph(ftFace.glyph, &glyph))
            throw new Exception("FT_Get_Glyph failed");

        FT_Glyph_To_Bitmap(&glyph, FT_RENDER_MODE_NORMAL, null, 1);
        FT_BitmapGlyph bitmapGlyph = cast(FT_BitmapGlyph)glyph;

        FT_Bitmap bitmap = bitmapGlyph.bitmap;

        int width = nextPowerOfTwo(bitmap.width);
        int height = nextPowerOfTwo(bitmap.rows);

        GLubyte[] img = New!(GLubyte[])(2 * width * height);

        foreach(j; 0..height)
        foreach(i; 0..width)
        {
            img[2 * (i + j * width)] = 255;
            img[2 * (i + j * width) + 1] =
                (i >= bitmap.width || j >= bitmap.rows)?
                 0 : bitmap.buffer[i + bitmap.width * j];
        }

        glBindTexture(GL_TEXTURE_2D, texId);
        glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MAG_FILTER, GL_NEAREST);
        glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MIN_FILTER, GL_NEAREST);
        glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_WRAP_S, GL_CLAMP_TO_EDGE);
        glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_WRAP_T, GL_CLAMP_TO_EDGE);

        glTexImage2D(GL_TEXTURE_2D,
            0, GL_RG8, width, height,
            0, GL_RG, GL_UNSIGNED_BYTE, img.ptr);

        Delete(img);

        Glyph g = Glyph(true, texId, glyph, width, height, ftFace.glyph.advance.x);
        glyphs[code] = g;

        return charIndex;
    }

    dchar loadChar(dchar code)
    {
        GLuint tex;
        glGenTextures(1, &tex);
        loadGlyph(code, tex);
        return code;
    }

    float renderGlyph(dchar code, float shift)
    {
        Glyph glyph;
        if (code in glyphs)
            glyph = glyphs[code];
        else
            glyph = glyphs[loadChar(code)];

        //if (!glyph.valid)
        //    return 0.0f;

        FT_BitmapGlyph bitmapGlyph = cast(FT_BitmapGlyph)(glyph.ftGlyph);
        FT_Bitmap bitmap = bitmapGlyph.bitmap;

        glBindTexture(GL_TEXTURE_2D, glyph.textureId);
        glUniform1i(glyphTextureLoc, 0);

        float chWidth = cast(float)bitmap.width;
        float chHeight = cast(float)bitmap.rows;
        float texWidth = cast(float)glyph.width;
        float texHeight = cast(float)glyph.height;

        float x = 0.5f / texWidth + chWidth / texWidth;
        float y = 0.5f / texHeight + chHeight / texHeight;

        Vector2f glyphPosition = Vector2f(shift + bitmapGlyph.left, height-bitmapGlyph.top); //-(bitmapGlyph.top - bitmap.rows))
        Vector2f glyphScale = Vector2f(bitmap.width, bitmap.rows);
        Vector2f glyphTexcoordScale = Vector2f(x, y);

        glUniform2fv(glyphPositionLoc, 1, glyphPosition.arrayof.ptr);
        glUniform2fv(glyphScaleLoc, 1, glyphScale.arrayof.ptr);
        glUniform2fv(glyphTexcoordScaleLoc, 1, glyphTexcoordScale.arrayof.ptr);

        glBindVertexArray(vao);
        glDrawElements(GL_TRIANGLES, cast(uint)indices.length * 3, GL_UNSIGNED_INT, cast(void*)0);
        glBindVertexArray(0);

        shift = glyph.advanceX >> 6;

        glBindTexture(GL_TEXTURE_2D, 0);

        return shift;
    }

    void renderGlyphUnit(dchar code)
    {
        Glyph glyph;
        if (code in glyphs)
            glyph = glyphs[code];
        else
            glyph = glyphs[loadChar(code)];

        //if (!glyph.valid)
        //    return 0.0f;

        FT_BitmapGlyph bitmapGlyph = cast(FT_BitmapGlyph)(glyph.ftGlyph);
        FT_Bitmap bitmap = bitmapGlyph.bitmap;

        glBindTexture(GL_TEXTURE_2D, glyph.textureId);
        glUniform1i(glyphTextureLoc, 0);

        float chWidth = cast(float)bitmap.width;
        float chHeight = cast(float)bitmap.rows;
        float texWidth = cast(float)glyph.width;
        float texHeight = cast(float)glyph.height;

        float x = 0.5f / texWidth + chWidth / texWidth;
        float y = 0.5f / texHeight + chHeight / texHeight;

        Vector2f glyphPosition = Vector2f(float(bitmapGlyph.left)/bitmap.width, height-bitmapGlyph.top); //-(bitmapGlyph.top - bitmap.rows))
        Vector2f glyphScale = Vector2f(1.0f, bitmap.rows);
        Vector2f glyphTexcoordScale = Vector2f(x, y);

        glUniform2fv(glyphPositionLoc, 1, glyphPosition.arrayof.ptr);
        glUniform2fv(glyphScaleLoc, 1, glyphScale.arrayof.ptr);
        glUniform2fv(glyphTexcoordScaleLoc, 1, glyphTexcoordScale.arrayof.ptr);

        glBindVertexArray(vao);
        glDrawElements(GL_TRIANGLES, cast(uint)indices.length * 3, GL_UNSIGNED_INT, cast(void*)0);
        glBindVertexArray(0);

        glBindTexture(GL_TEXTURE_2D, 0);
    }

    int glyphAdvance(dchar code)
    {
        Glyph glyph;
        if (code in glyphs)
            glyph = glyphs[code];
        else
            glyph = glyphs[loadChar(code)];
        return cast(int)(glyph.advanceX >> 6);
    }

    void bind(RenderingContext* rc){
        glUseProgram(shaderProgram);
        glUniformMatrix4fv(projectionMatrixLoc, 1, GL_FALSE, rc.projectionMatrix.arrayof.ptr);
    }
    void unbind(RenderingContext* rc){
        glUseProgram(0);
    }
    void setTransformationScaled(Vector3f position,Vector3f scale,RenderingContext* rc){
        import dlib.math.transformation;
        auto matrix=rc.viewMatrix*translationMatrix(position)*scaleMatrix(scale);
        glUniformMatrix4fv(modelViewMatrixLoc, 1, GL_FALSE, matrix.arrayof.ptr);
    }
    void setColor(Color4f color){
        glUniform4fv(glyphColorLoc, 1, color.arrayof.ptr);
    }

    override void render(RenderingContext* rc, Color4f color, const(char)[] str)
    {
        if (!canRender)
            return;

        glUseProgram(shaderProgram);

        glUniformMatrix4fv(modelViewMatrixLoc, 1, GL_FALSE, rc.modelViewMatrix.arrayof.ptr);
        glUniformMatrix4fv(projectionMatrixLoc, 1, GL_FALSE, rc.projectionMatrix.arrayof.ptr);

        glUniform4fv(glyphColorLoc, 1, color.arrayof.ptr);

        float shift = 0.0f;
        UTF8Decoder dec = UTF8Decoder(str);
        int ch;
        do
        {
            ch = dec.decodeNext();
            if (ch == 0 || ch == UTF8_END || ch == UTF8_ERROR) break;
            dchar code = ch;
            if (code.isASCII)
            {
                if (code.isPrintable)
                    shift += renderGlyph(code, shift);
            }
            else
                shift += renderGlyph(code, shift);
        } while(ch != UTF8_END && ch != UTF8_ERROR);

        glUseProgram(0);
    }

    override float width(string str)
    {
        float width = 0.0f;
        UTF8Decoder dec = UTF8Decoder(str);
        int ch;
        do
        {
            ch = dec.decodeNext();
            if (ch == 0 || ch == UTF8_END || ch == UTF8_ERROR) break;
            dchar code = ch;
            if (code.isASCII)
            {
                if (code.isPrintable)
                    width += glyphAdvance(code);
            }
            else
                width += glyphAdvance(code);
        } while(ch != UTF8_END && ch != UTF8_ERROR);

        return width;
    }
}
