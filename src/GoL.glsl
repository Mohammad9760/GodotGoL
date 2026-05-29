#[compute]
#version 460
layout(local_size_x = 16, local_size_y = 16, local_size_z = 1) in;

layout(rg8, set = 0, binding = 0) uniform restrict image2D backBuffer;
layout(rg8, set = 1, binding = 0) uniform restrict image2D outBuffer;

// Parameters
layout(push_constant, std430) uniform Params
{
    float after_glow;
    float pointer_radius;
    float pointer_x;
    float pointer_y;
    float pointer_buttons;
    float buffer_width;
    float buffer_height;
    float wrap_borders;
} params;


// a wrap clamp function that uses integers
int wrapClamp(int a, int b, int value)
{
    if(value > b)
    {
        return a + (abs(b - value));
    }
    if(value < a)
    {
        return b - (abs(a - value));
    }
    return value;
}

// can't use this due to floating point precision errors
// float wrapClamp(float a, float b, float value)
// {
//     float t = (value - a) / (b - a);
//     return mix(a, b, mod(t, 1.0));
// }

// get the life state of the neighbor at [x,y] to the current cell
float neighbor(int x, int y)
{
    ivec2 pos = ivec2(gl_GlobalInvocationID.xy) + ivec2(x, y);

    // if the neighbor is outside the borders of the buffer, sample the cells one the other side
    if(params.wrap_borders > 0.)
    {
        pos.x = (wrapClamp(0, int(params.buffer_width) - 1, (pos.x)));
        pos.y = (wrapClamp(0, int(params.buffer_height) - 1, (pos.y)));
    }
   
    return imageLoad(backBuffer, pos).r;
}

vec2 evaluate(float population)
{
    // x = alive, y = after glow
    vec2 cell = imageLoad(backBuffer, ivec2(gl_GlobalInvocationID.xy)).rg;
    float has3 = step(abs(population - 3.0), 0.1);
    float has2 = step(abs(population - 2.0), 0.1);
    // the cell survives if it has 3 neighbors OR (has 2 neighbors AND is alive itself)
    float survives = has3 + (has2 * cell.r);
    return vec2(survives, max(cell.g * params.after_glow, survives));
}

// Game Of Life
void main() 
{	
    // the sum of the living neighboring cells
    float population = 
        neighbor(-1, -1)
        + neighbor(0, -1)
        + neighbor(1, -1)
        + neighbor(-1, 0)
        + neighbor(-1, 1)
        + neighbor(1, 0) 
        + neighbor(1, 1) 
        + neighbor(0, 1);


    if(params.pointer_buttons != 0.0) // if there's a mouse button pressed
        // check if the current cell is close enough to the mouse pointer
        if(distance(gl_GlobalInvocationID.xy, vec2(params.pointer_x, params.pointer_y)) <= params.pointer_radius)
            // if RMB is pressed kill every cell, if LMB is pressed make them alive (population = 3)
            population = mix(0.0, 3.0, step(0.0, params.pointer_buttons));


    // update the simulation world
	imageStore(outBuffer, ivec2(gl_GlobalInvocationID.xy), vec4(evaluate(population), vec2(0.0)));
}
