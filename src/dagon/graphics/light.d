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

module dagon.graphics.light;

import std.stdio;
import std.math;
import std.conv;
import std.random;
import core.time;

import dlib.core.memory;
import dlib.math.vector;
import dlib.container.array;
import dlib.image.color;
import dlib.geometry.frustum;

import derelict.opengl;

import dagon.core.ownership;
import dagon.graphics.view;
import dagon.graphics.rc;
import dagon.logics.entity;
import dagon.logics.behaviour;

float clampf(float x, float mi, float ma)
{
    if (x < mi) return mi;
    else if (x > ma) return ma;
    else return x;
}

struct Box
{
    Vector2f pmin;
    Vector2f pmax;
}

struct Circle
{
    Vector2f center;
    float radius;
}

Box cellBox(uint x, uint y, float cellSize, float domainWidth)
{
    Box b;
    b.pmin = Vector2f(x, y) * cellSize - domainWidth * 0.5f;
    b.pmax = b.pmin + cellSize;
    return b;
}

bool circleBoxIsec(Circle c, Box b)
{
    if (c.center.x > b.pmin.x && c.center.x < b.pmax.x &&
        c.center.y > b.pmin.y && c.center.y < b.pmax.y)
        return true; // sphere's center is inside the box

    Vector2f closest = c.center;
    for (int i = 0; i < 2; i++)
    {
        float v = c.center[i];
        if (v < b.pmin[i]) v = b.pmin[i];
        if (v > b.pmax[i]) v = b.pmax[i];
        closest[i] = v;
    }

    return (distance(c.center, closest) <= c.radius);
}

class LightSource
{
    Vector3f position;
    Vector3f color;
    float radius; // max light attenuation radius
    float areaRadius; // light's own radius
    float energy;
    
    this(Vector3f pos, Vector3f col, float attRadius, float areaRadius, float energy)
    {
        this.position = pos;
        this.color = col;
        this.radius = attRadius;
        this.areaRadius = areaRadius;
        this.energy = energy;
    }
}

enum uint maxLightsPerNode = 8;

struct LightCluster
{
    Box box;
    
    uint[maxLightsPerNode] lights;
    uint numLights = 0;
}

// TODO: move this to dlib.geometry.frustum
bool frustumIntersectsSphere(ref Frustum f, Vector3f center, float radius)
{
	float d;

	foreach(i, ref p; f.planes)
    {
		// find the signed distance to this plane
		d = p.distance(center);

		// if this distance is > sphere.radius, we are outside
		if (d > radius)
			return false;
	}

	return true;
}

class LightManager: Owner
{    
    DynamicArray!LightSource lightSources;
    LightCluster[] clusterData;
    
    uint[] clusters;
    Vector3f[] lights;
    uint[] lightIndices;
    
    Vector3f position;
    
    Vector2f clustersPosition;
    float sceneSize = 200.0f;
    float invSceneSize;
    float clusterSize;
    uint domainSize = 100;
    
    uint numLightAttributes = 4;
    
    uint maxNumLights;
    uint maxNumIndices = 2048;
    
    uint currentlyVisibleLights = 0;
    
    GLuint clusterTexture;
    GLuint lightTexture;
    GLuint indexTexture;
    
    this(float sceneSize, uint numClusters, Owner o)
    {
        super(o);
        
        position = Vector3f(0, 0, 0);
        
        this.sceneSize = sceneSize;
        this.domainSize = numClusters;
        
        invSceneSize = 1.0f / sceneSize;
        
        clusterSize = sceneSize / cast(float)domainSize;
        clustersPosition = Vector2f(-sceneSize * 0.5f, -sceneSize * 0.5f);
        clusterData = New!(LightCluster[])(domainSize * domainSize);
        
        foreach(y; 0..domainSize)
        foreach(x; 0..domainSize)
        {
            LightCluster* c = &clusterData[y * domainSize + x];
            c.box = cellBox(x, y, clusterSize, sceneSize);
            c.numLights = 0;
        }

        clusters = New!(uint[])(domainSize * domainSize);
        
        foreach(ref c; clusters)
            c = 0;
            
        maxNumLights = maxNumIndices / maxLightsPerNode;
        
        lights = New!(Vector3f[])(maxNumLights * numLightAttributes);
        foreach(ref l; lights)
            l = Vector3f(0, 0, 0);

        lightIndices = New!(uint[])(maxNumIndices);
        
        // 2D texture to store light clusters
        glGenTextures(1, &clusterTexture);
        glActiveTexture(GL_TEXTURE0);
        glBindTexture(GL_TEXTURE_2D, clusterTexture);
        glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MIN_FILTER, GL_NEAREST);
        glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MAG_FILTER, GL_NEAREST);
        glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_WRAP_S, GL_CLAMP_TO_EDGE);
        glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_WRAP_T, GL_CLAMP_TO_EDGE);
        glTexImage2D(GL_TEXTURE_2D, 0, GL_R32UI, domainSize, domainSize, 0, GL_RED_INTEGER, GL_UNSIGNED_INT, clusters.ptr);
        glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_BASE_LEVEL, 0);
        glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MAX_LEVEL, 0);
        glBindTexture(GL_TEXTURE_2D, 0);

        // 2D texture to store light data
        glGenTextures(1, &lightTexture);
        glBindTexture(GL_TEXTURE_2D, lightTexture);
        glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MIN_FILTER, GL_NEAREST);
        glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MAG_FILTER, GL_NEAREST);
        glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_WRAP_S, GL_CLAMP_TO_EDGE);
        glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_WRAP_T, GL_CLAMP_TO_EDGE);
        glTexImage2D(GL_TEXTURE_2D, 0, GL_RGB32F, maxNumLights, numLightAttributes, 0, GL_RGB, GL_FLOAT, lights.ptr);
        glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_BASE_LEVEL, 0);
        glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MAX_LEVEL, 0);
        glBindTexture(GL_TEXTURE_2D, 0);
        
        // 1D texture to store light indices per cluster
        glGenTextures(1, &indexTexture);
        glBindTexture(GL_TEXTURE_1D, indexTexture);
        glTexParameteri(GL_TEXTURE_1D, GL_TEXTURE_MIN_FILTER, GL_NEAREST);
        glTexParameteri(GL_TEXTURE_1D, GL_TEXTURE_MAG_FILTER, GL_NEAREST);
        glTexParameteri(GL_TEXTURE_1D, GL_TEXTURE_WRAP_S, GL_CLAMP_TO_EDGE);
        glTexParameteri(GL_TEXTURE_1D, GL_TEXTURE_WRAP_T, GL_CLAMP_TO_EDGE);
        glTexImage1D(GL_TEXTURE_1D, 0, GL_R32UI, maxNumIndices, 0, GL_RED_INTEGER, GL_UNSIGNED_INT, lightIndices.ptr);
        glTexParameteri(GL_TEXTURE_1D, GL_TEXTURE_BASE_LEVEL, 0);
        glTexParameteri(GL_TEXTURE_1D, GL_TEXTURE_MAX_LEVEL, 0);
        glBindTexture(GL_TEXTURE_1D, 0);
    }
    
    ~this()
    {
        if (glIsTexture(clusterTexture))
            glDeleteTextures(1, &clusterTexture);
            
        if (glIsTexture(lightTexture))
            glDeleteTextures(1, &lightTexture);
            
        if (glIsTexture(indexTexture))
            glDeleteTextures(1, &indexTexture);
    
        Delete(clusters);
        Delete(lights);
        Delete(lightIndices);
        
        foreach(light; lightSources)
            Delete(light);
        
        lightSources.free();
        Delete(clusterData);
    }
    
    LightSource addLight(Vector3f position, Color4f color, float energy, float radius, float areaRadius = 0.0f)
    {        
        lightSources.append(New!LightSource(position, color.rgb, radius, areaRadius, energy));
        
        if (lightSources.length >= maxNumLights)
            writeln("Warning: lights number exceeds index buffer capability (", maxNumLights, ")");
        
        return lightSources.data[$-1];
    }
    
    void bindClusterTexture()
    {
        glBindTexture(GL_TEXTURE_2D, clusterTexture);
    }
    void unbindClusterTexture()
    {
        glBindTexture(GL_TEXTURE_2D, 0);
    }
    
    void bindLightTexture()
    {
        glBindTexture(GL_TEXTURE_2D, lightTexture);
    }
    void unbindLightTexture()
    {
        glBindTexture(GL_TEXTURE_2D, 0);
    }
    
    void bindIndexTexture()
    {
        glBindTexture(GL_TEXTURE_1D, indexTexture);
    }
    void unbindIndexTexture()
    {
        glBindTexture(GL_TEXTURE_1D, 0);
    }
    
    void update(RenderingContext* rc)
    {
        position = rc.cameraPosition;
    
        foreach(ref v; clusters)
            v = 0;
            
        foreach(ref c; clusterData)
        {        
            c.numLights = 0;
        }
        
        currentlyVisibleLights = 0;

        foreach(i, light; lightSources.data)
        {
            if (frustumIntersectsSphere(rc.frustum, light.position, light.radius))
            {
                currentlyVisibleLights++;
                
                if (currentlyVisibleLights < maxNumLights)
                {
                    uint index = currentlyVisibleLights - 1;
                    
                    lights[index] = light.position;
                    lights[maxNumLights + index] = light.color;
                    lights[maxNumLights * 2 + index] = Vector3f(light.radius, light.areaRadius, light.energy);

                    Vector3f lightPosLocal = light.position - position;
                    Vector2f lightPosXZ = Vector2f(lightPosLocal.x, lightPosLocal.z);
                    Circle lightCircle = Circle(lightPosXZ, light.radius);
                    
                    uint x1 = cast(uint)clampf(floor((lightCircle.center.x - lightCircle.radius + sceneSize * 0.5f) / clusterSize), 0, domainSize-1);
                    uint y1 = cast(uint)clampf(floor((lightCircle.center.y - lightCircle.radius + sceneSize * 0.5f) / clusterSize), 0, domainSize-1);
                    uint x2 = cast(uint)clampf(x1 + ceil(lightCircle.radius + lightCircle.radius) + 1, 0, domainSize-1);
                    uint y2 = cast(uint)clampf(y1 + ceil(lightCircle.radius + lightCircle.radius) + 1, 0, domainSize-1);

                    foreach(y; y1..y2)
                    foreach(x; x1..x2)
                    {
                        Box b = cellBox(x, y, clusterSize, sceneSize);
                        if (circleBoxIsec(lightCircle, b))
                        {
                            auto c = &clusterData[y * domainSize + x];
                            if (c.numLights < maxLightsPerNode)
                            {
                                c.lights[c.numLights] = index;
                                c.numLights = c.numLights + 1;
                            }
                        }
                    }
                }
                else
                    break;
            }
        }
        
        uint offset = 0;
        foreach(ci, ref c; clusterData)
        if (offset < maxNumIndices)
        {
            if (offset + c.numLights > maxNumIndices)
                break;
        
            if (c.numLights)
            {                
                foreach(i; 0..c.numLights)
                    lightIndices[offset + cast(uint)i] = c.lights[i];

                clusters[ci] = offset | (c.numLights << 16);
                
                offset += c.numLights;
            }
            else
            {
                clusters[ci] = 0;
            }
        }

        glBindTexture(GL_TEXTURE_2D, clusterTexture);
        glTexSubImage2D(GL_TEXTURE_2D, 0, 0, 0, domainSize, domainSize, GL_RED_INTEGER, GL_UNSIGNED_INT, clusters.ptr);
        glBindTexture(GL_TEXTURE_2D, 0);
        
        glBindTexture(GL_TEXTURE_2D, lightTexture);
        glTexSubImage2D(GL_TEXTURE_2D, 0, 0, 0, maxNumLights, numLightAttributes, GL_RGB, GL_FLOAT, lights.ptr);
        glBindTexture(GL_TEXTURE_2D, 0);
        
        glBindTexture(GL_TEXTURE_1D, indexTexture);
        glTexSubImage1D(GL_TEXTURE_1D, 0, 0, maxNumIndices, GL_RED_INTEGER, GL_UNSIGNED_INT, lightIndices.ptr);
        glBindTexture(GL_TEXTURE_1D, 0);
    }
}

// Attach a light to Entity
class LightBehaviour: Behaviour
{
    LightSource light;

    this(Entity e, LightSource light)
    {
        super(e);
        
        this.light = light;
    }

    override void update(Duration dt)
    {
        light.position = entity.position;
    }
}
