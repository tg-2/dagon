/*
Copyright (c) 2013-2018 Timur Gafarov 

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

module dmech.clipping;

import dlib.math.vector;

/*
 * 2D feature clipping.
 * Feature is a quad, triangle, line segment or point 
 */

struct Feature
{
    Vector2f[4] vertices;
    uint numVertices = 0;
}

bool pointInPolygon(Vector2f[] vert, uint len, Vector2f point)
{
    int i, j = 0;
    bool c = false;
    for (i = 0, j = len - 1; i < len; j = i++)
    {
        if ( ((vert[i].y > point.y) != (vert[j].y > point.y)) &&
             (point.x < (vert[j].x - vert[i].x) * (point.y - vert[i].y) / (vert[j].y - vert[i].y) + vert[i].x) )
            c = !c;
    }
    return c;
}

void featurePointsIn(Feature f1, Feature f2, ref bool[4] res)
{
    for (uint i = 0; i < f1.numVertices; i++)
        res[i] = pointInPolygon(f2.vertices, f2.numVertices, f1.vertices[i]);        
}

bool allIsTrue(ref bool[4] arr, uint len)
{
    for (uint i = 0; i < len; i++)
        if (!arr[i]) 
            return false;
    return true;
}

// Detect intersection of two line segments
bool segmentIsec(
    Vector2f start1, Vector2f end1, 
    Vector2f start2, Vector2f end2, 
    out Vector2f out_intersection)
{
    Vector2f dir1 = end1 - start1;
    Vector2f dir2 = end2 - start2;

    float a1 = -dir1.y;
    float b1 = +dir1.x;
    float d1 = -(a1*start1.x + b1*start1.y);

    float a2 = -dir2.y;
    float b2 = +dir2.x;
    float d2 = -(a2*start2.x + b2*start2.y);

    float seg1_line2_start = a2*start1.x + b2*start1.y + d2;
    float seg1_line2_end = a2*end1.x + b2*end1.y + d2;

    float seg2_line1_start = a1*start2.x + b1*start2.y + d1;
    float seg2_line1_end = a1*end2.x + b1*end2.y + d1;

    if (seg1_line2_start * seg1_line2_end >= 0 || 
        seg2_line1_start * seg2_line1_end >= 0) 
        return false;

    float u = seg1_line2_start / (seg1_line2_start - seg1_line2_end);
    out_intersection = start1 + dir1 * u;

    return true;
}

T distancesqr2(T) (Vector!(T,2) a, Vector!(T,2) b)
do
{
    T dx = a.x - b.x;
    T dy = a.y - b.y;
    return ((dx * dx) + (dy * dy));
}

// Perform clipping of two features
bool clip(
    Feature f1,
    Feature f2,
    out Vector2f[8] outPts, 
    out uint numOutPts) 
{
/*
    if (f1.numVertices == 1)
    {
        outPts[0] = f1.vertices[0];
        numOutPts = 1;
    }
    if (f2.numVertices == 1)
    {
        outPts[0] = f2.vertices[0];
        numOutPts = 1;
    }
*/

    // Check if features are almost the same
    if (f1.numVertices == f2.numVertices)
    {
        bool same = false;
        for (uint i = 0; i < f1.numVertices; i++)
            same = same || distancesqr2(f1.vertices[i], f2.vertices[i]) < 0.001f;
        if (same)
        {
            // result is f1
            for (uint i = 0; i < f1.numVertices; i++)
                outPts[i] = f1.vertices[i];
            numOutPts = f1.numVertices;
            return true;
        }
    }

    // Check if one feature fully encloses another
    bool[4] r1;
    bool[4] r2;

    if (f2.numVertices > 2)
        featurePointsIn(f1, f2, r1);
    if (f1.numVertices > 2)
        featurePointsIn(f2, f1, r2);

    if (allIsTrue(r1, f1.numVertices))
    {
        // f2 fully encloses f1, result is f1
        for (uint i = 0; i < f1.numVertices; i++)
            outPts[i] = f1.vertices[i];
        numOutPts = f1.numVertices;
        return true;
    }

    if (allIsTrue(r2, f2.numVertices))
    {
        // f1 fully encloses f2, result is f2
        for (uint i = 0; i < f2.numVertices; i++)
            outPts[i] = f2.vertices[i];
        numOutPts = f2.numVertices;
        return true;
    }

    // Add enclosed points to result
    numOutPts = 0;
    foreach(i, r; r1)
    if (r)
    {
        outPts[numOutPts] = f1.vertices[i];
        numOutPts++;
    }
    foreach(i, r; r2)
    if (r)
    {
        outPts[numOutPts] = f2.vertices[i];
        numOutPts++;
    }

    // Check one feature's edges against another's
    // TODO: check only those edges that belong to enclosed points
    for (uint i = 0; i < f1.numVertices; i++)
    for (uint j = 0; j < f2.numVertices; j++)
    {
        uint i2 = i + 1;
        if (i2 == f1.numVertices) i2 = 0;
        uint j2 = j + 1;
        if (j2 == f2.numVertices) j2 = 0;

        Vector2f a = f1.vertices[i];
        Vector2f b = f1.vertices[i2];
        Vector2f c = f2.vertices[j];
        Vector2f d = f2.vertices[j2];

        Vector2f ip;
        if (segmentIsec(a, b, c, d, ip))
        {
            if (numOutPts < 8)
            {
                outPts[numOutPts] = ip;
                numOutPts++;
            }
        }
    }

    return (numOutPts > 0);
}

