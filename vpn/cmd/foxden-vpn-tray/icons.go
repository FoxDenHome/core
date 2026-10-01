package main

import (
	"bytes"
	"image"
	"image/color"
	"image/png"
	"math"
)

// Icons are drawn at startup rather than shipped as assets: a shield, filled
// when connected, outlined when idle, with a dot when at home and a slash when
// off. macOS gets black template images; Linux panels get colored ones.

type glyph int

const (
	glyphConnected glyph = iota
	glyphIdle
	glyphLAN
	glyphOff
)

const iconSize = 64

// shield reports whether (x, y) in [0,1]² lies inside a shield scaled by s
// about its center.
func shield(x, y, s float64) bool {
	x = (x-0.5)/s + 0.5
	y = (y-0.52)/s + 0.52
	const top, mid, bottom, half = 0.08, 0.45, 0.95, 0.36
	if y < top || y > bottom {
		return false
	}
	w := half
	if y > mid {
		t := (y - mid) / (bottom - mid)
		w = half * (1 - t*t) * (1 + 0.35*t)
	}
	// The top edge dips towards the middle.
	if y < top+0.1*(1-math.Abs(x-0.5)/half) {
		return false
	}
	return math.Abs(x-0.5) <= w
}

func cover(g glyph, x, y float64) bool {
	outer := shield(x, y, 1)
	switch g {
	case glyphConnected:
		return outer
	case glyphLAN:
		dx, dy := x-0.5, y-0.47
		return (outer && !shield(x, y, 0.72)) || dx*dx+dy*dy < 0.017
	case glyphOff:
		// Diagonal slash, cut out of the outline next to it for contrast.
		d := (x - y) / math.Sqrt2
		if math.Abs(d) < 0.055 && x > 0.08 && x < 0.92 {
			return true
		}
		return outer && !shield(x, y, 0.72) && math.Abs(d) > 0.11
	default:
		return outer && !shield(x, y, 0.72)
	}
}

func render(g glyph, c color.NRGBA) []byte {
	img := image.NewNRGBA(image.Rect(0, 0, iconSize, iconSize))
	const ss = 4 // supersampling for antialiasing
	for py := 0; py < iconSize; py++ {
		for px := 0; px < iconSize; px++ {
			n := 0
			for sy := 0; sy < ss; sy++ {
				for sx := 0; sx < ss; sx++ {
					x := (float64(px) + (float64(sx)+0.5)/ss) / iconSize
					y := (float64(py) + (float64(sy)+0.5)/ss) / iconSize
					if cover(g, x, y) {
						n++
					}
				}
			}
			if n > 0 {
				img.SetNRGBA(px, py, color.NRGBA{c.R, c.G, c.B, uint8(int(c.A) * n / (ss * ss))})
			}
		}
	}
	var buf bytes.Buffer
	_ = png.Encode(&buf, img)
	return buf.Bytes()
}

type iconSet struct {
	template []byte
	regular  []byte
}

var (
	colorConnected = color.NRGBA{0x3d, 0xae, 0xe9, 0xff} // Breeze highlight blue
	colorLAN       = color.NRGBA{0x27, 0xae, 0x60, 0xff}
	colorNeutral   = color.NRGBA{0x93, 0x99, 0xa0, 0xff}
	colorAttention = color.NRGBA{0xf6, 0x74, 0x00, 0xff}
	colorTemplate  = color.NRGBA{0, 0, 0, 0xff}
)

func makeIcon(g glyph, c color.NRGBA) iconSet {
	return iconSet{template: render(g, colorTemplate), regular: render(g, c)}
}

var (
	iconConnected = makeIcon(glyphConnected, colorConnected)
	iconIdle      = makeIcon(glyphIdle, colorNeutral)
	iconLAN       = makeIcon(glyphLAN, colorLAN)
	iconOff       = makeIcon(glyphOff, colorNeutral)
	iconAttention = makeIcon(glyphOff, colorAttention)
)
