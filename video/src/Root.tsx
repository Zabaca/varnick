import React from "react";
import { Composition } from "remotion";
import { FPS, totalFrames, Video, type Shape, type Theme } from "./Video";

const SIZES: Record<Shape, { width: number; height: number }> = {
  landscape: { width: 1920, height: 1080 },
  square: { width: 1080, height: 1080 },
};

const comp = (id: string, shape: Shape, theme: Theme) => (
  <Composition
    key={id}
    id={id}
    component={Video}
    durationInFrames={totalFrames()}
    fps={FPS}
    {...SIZES[shape]}
    defaultProps={{ shape, theme }}
  />
);

export const Root: React.FC = () => (
  <>
    {comp("Landscape", "landscape", "light")}
    {comp("Square", "square", "light")}
    {comp("LandscapeDark", "landscape", "dark")}
    {comp("SquareDark", "square", "dark")}
  </>
);
