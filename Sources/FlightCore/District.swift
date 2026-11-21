import Foundation
import simd

/// One building or structure of an industrial or city site. Solid: the model crashes into it, and it shelters the
/// wind. `round` structures are cylinders of diameter `w`; the rest are boxes `w` wide (x) and `d` deep (z).
struct Block {
    var x: Float, z: Float, y: Float            // centre on the ground
    var w: Float, d: Float, h: Float
    var kind: Int
    var seed: UInt64
    var round = false
    var solidH: Float { kind == 5 ? h * 1.4 : (kind == 11 ? h * 1.3 : h) }
    func contains(_ p: V3, margin: Float = 0) -> Bool {
        guard p.y < y + solidH + margin, p.y > y - 2 else { return false }
        if round { let r = w / 2 + margin; return (p.x - x) * (p.x - x) + (p.z - z) * (p.z - z) < r * r }
        return abs(p.x - x) < w / 2 + margin && abs(p.z - z) < d / 2 + margin
    }
}

/// Kinds of block.
enum BK {
    static let warehouse = 0, factory = 1, office = 2, apartment = 3, tower = 4, house = 5, tank = 6, chimney = 7, cooling = 8
    static let containers = 9, crane = 10, church = 11, gasHolder = 12, pylon = 13, ship = 14, stadium = 15, spire = 16
    static let column = 17, hall = 18, lamp = 19, brickChimney = 20, bridge = 21
}

extension Terrain {
    /// Lay out the buildings of an industrial or city site. The flying field, the area in front of the pilot and the
    /// club corner stay clear.
    func layoutDistrict() -> [Block] {
        let d = site.district
        guard d > 0, site.panorama == nil else { return [] }
        var rng = LCG(UInt64(site.seed) + 777)
        var out: [Block] = []
        let hl = site.runwayLen / 2, hw = site.runwayWid / 2
        let clearX = hl + site.districtClear.x, clearFront = -site.districtClear.y, clearBack = hw + 62

        func size(_ k: Int, _ s: Float) -> (Float, Float, Float, Bool) {
            switch k {
            case BK.warehouse: return (rng.range(30, 70) * s, rng.range(22, 40) * s, rng.range(8, 13) * s, false)
            case BK.factory: return (rng.range(40, 80), rng.range(30, 50), rng.range(10, 16), false)
            case BK.office: return (rng.range(18, 40), rng.range(14, 22), rng.range(14, 45) * s, false)
            case BK.apartment: return (rng.range(20, 50), rng.range(12, 16), rng.range(12, 34) * s, false)
            case BK.tower: let w = rng.range(22, 36); return (w, w * rng.range(0.8, 1.2), rng.range(60, 170) * s, false)
            case BK.house: return (rng.range(8, 12), rng.range(7, 9), rng.range(5.5, 7), false)
            case BK.tank: let r = rng.range(12, 28); return (r, r, rng.range(8, 16), true)
            case BK.chimney: let r = rng.range(3.5, 5.5); return (r, r, rng.range(45, 95) * s, true)
            case BK.cooling: let r = rng.range(46, 56); return (r, r, rng.range(65, 85), true)
            case BK.containers: return (12.4, 7.6, 2.6 * Float(1 + Int(rng.next() * 3.99)), false)
            case BK.crane: return (22, 30, 55, false)
            case BK.church: return (13, 30, 15, false)
            case BK.gasHolder: let r = rng.range(36, 52); return (r, r, rng.range(30, 45), true)
            case BK.pylon: return (5, 5, 38, false)
            case BK.ship: return (rng.range(110, 150), 22, 14, false)
            case BK.stadium: return (190, 150, 28, false)
            case BK.spire: return (6.5, 6.5, 48, false)
            case BK.column: let r = rng.range(4, 7); return (r, r, rng.range(25, 50), true)
            case BK.hall: return (rng.range(90, 140), rng.range(40, 55), rng.range(22, 30), false)
            case BK.lamp: return (0.5, 0.5, 9, true)
            case BK.brickChimney: return (4.5, 4.5, rng.range(30, 50), false)
            default: return (16, 160, 9, false)
            }
        }
        @discardableResult func add(_ k: Int, _ x: Float, _ z: Float, scale s: Float = 1, onWater: Bool = false, gap: Float = 9) -> Bool {
            let (w, dd, hh, round) = size(k, s)
            // clear of the flying field, the pilots and the clubhouse
            if x + w / 2 > -clearX && x - w / 2 < clearX && z + dd / 2 > clearFront && z - dd / 2 < clearBack { return false }
            if abs(x) > 1150 || abs(z) > 1150 { return false }
            let y = height(x, z)
            if !onWater {
                if let wl = site.waterLevel, min(height(x - w / 2, z - dd / 2), height(x + w / 2, z + dd / 2), height(x - w / 2, z + dd / 2), height(x + w / 2, z - dd / 2), y) < wl + 0.6 { return false }
                if abs(height(x - w / 2, z) - height(x + w / 2, z)) > 3.5 || abs(height(x, z - dd / 2) - height(x, z + dd / 2)) > 3.5 { return false }
            }
            for b in out where abs(b.x - x) < (b.w + w) / 2 + gap && abs(b.z - z) < (b.d + dd) / 2 + gap { return false }
            out.append(Block(x: x, z: z, y: onWater ? (site.waterLevel ?? y) : y, w: w, d: dd, h: hh, kind: k, seed: UInt64(out.count) &* 7919 &+ UInt64(site.seed), round: round))
            return true
        }
        func scatter(_ n: Int, _ kinds: [Int], _ x0: Float, _ x1: Float, _ z0: Float, _ z1: Float, scale: Float = 1, gap: Float = 9) {
            var placed = 0, tries = 0
            while placed < n && tries < n * 40 {
                tries += 1
                if add(kinds[Int(rng.next() * Float(kinds.count) * 0.999)], rng.range(x0, x1), rng.range(z0, z1), scale: scale, gap: gap) { placed += 1 }
            }
        }
        /// Scatter in a ring round the field.
        func ring(_ n: Int, _ kinds: [Int], _ r0: Float, _ r1: Float, scale: Float = 1, gap: Float = 9) {
            var placed = 0, tries = 0
            while placed < n && tries < n * 40 {
                tries += 1
                let a = rng.range(0, 2 * .pi), r = rng.range(r0, r1)
                if add(kinds[Int(rng.next() * Float(kinds.count) * 0.999)], cos(a) * r * 1.25, sin(a) * r, scale: scale, gap: gap) { placed += 1 }
            }
        }
        func row(_ k: Int, x0: Float, x1: Float, z0: Float, z1: Float, count: Int, scale: Float = 1, onWater: Bool = false, gap: Float = 3) {
            for i in 0..<count {
                let t = count > 1 ? Float(i) / Float(count - 1) : 0.5
                add(k, lerp(x0, x1, t), lerp(z0, z1, t), scale: scale, onWater: onWater, gap: gap)
            }
        }
        let back0 = clearBack + 30

        switch d {
        case 1:     // freight yard
            scatter(34, [BK.warehouse, BK.warehouse, BK.factory, BK.containers, BK.containers], -620, 620, -600, clearFront - 20)
            scatter(14, [BK.containers, BK.containers, BK.warehouse, BK.tank], -560, -clearX - 15, clearFront, 260)
            scatter(14, [BK.containers, BK.containers, BK.warehouse, BK.tank], clearX + 15, 560, clearFront, 260)
            scatter(20, [BK.warehouse, BK.factory, BK.tank], -560, 560, back0, 480)
            add(BK.chimney, -330, -470); add(BK.chimney, 410, -520)
            row(BK.lamp, x0: -hl - 40, x1: hl + 40, z0: clearBack + 6, z1: clearBack + 6, count: 7)
        case 2:     // container port: quay along z = -150, water beyond
            row(BK.crane, x0: -430, x1: 430, z0: -131, z1: -131, count: 6)
            add(BK.ship, -260, -186, onWater: true); add(BK.ship, 250, -190, onWater: true); add(BK.ship, 20, -420, onWater: true)
            scatter(34, [BK.containers], -640, -clearX - 10, -105, 240, gap: 4)
            scatter(34, [BK.containers], clearX + 10, 640, -105, 240, gap: 4)
            scatter(12, [BK.warehouse, BK.warehouse, BK.office], -560, 560, back0, 480)
            row(BK.lamp, x0: -420, x1: 420, z0: clearBack + 8, z1: clearBack + 8, count: 9)
        case 3:     // power station
            add(BK.cooling, -300, -540); add(BK.cooling, -170, -640); add(BK.cooling, -60, -540)
            add(BK.hall, 200, -480); add(BK.chimney, 150, -560, scale: 1.25); add(BK.chimney, 250, -565, scale: 1.25)
            row(BK.pylon, x0: 420, x1: 900, z0: -420, z1: 380, count: 6)
            row(BK.pylon, x0: 380, x1: -500, z0: -330, z1: -280, count: 6)
            scatter(16, [BK.tank, BK.warehouse], -600, 600, -440, clearFront - 30)
            scatter(14, [BK.warehouse, BK.office], -520, 520, back0, 460)
        case 4:     // steelworks
            add(BK.hall, -280, -360); add(BK.hall, -100, -470); add(BK.hall, 130, -380); add(BK.hall, 330, -480)
            for (cx, cz) in [(Float(-360), Float(-470)), (-190, -390), (20, -500), (230, -440), (420, -400)] { add(BK.chimney, cx, cz) }
            add(BK.gasHolder, -470, -300); add(BK.gasHolder, 520, -330)
            scatter(10, [BK.tank, BK.factory, BK.brickChimney], -600, 600, -620, clearFront - 40)
            scatter(8, [BK.factory, BK.warehouse], -600, -clearX - 20, clearFront, 220)
            scatter(8, [BK.factory, BK.warehouse], clearX + 20, 600, clearFront, 220)
            scatter(8, [BK.warehouse, BK.office], -500, 500, back0, 440)
        case 5:     // refinery
            scatter(26, [BK.tank], -620, 620, -640, clearFront - 30, gap: 14)
            scatter(14, [BK.column, BK.column, BK.tank], 60, 330, -470, -300, gap: 5)
            add(BK.chimney, -420, -430); add(BK.chimney, 470, -520)
            scatter(12, [BK.tank], -620, -clearX - 20, clearFront, 240, gap: 14)
            scatter(12, [BK.tank, BK.warehouse], clearX + 20, 620, clearFront, 240, gap: 14)
            scatter(6, [BK.warehouse, BK.office], -500, 500, back0, 420)
        case 6:     // quarry: plant on the pit floor
            scatter(5, [BK.tank, BK.warehouse], clearX + 5, 235, -150, 150, scale: 0.6)
            scatter(4, [BK.warehouse, BK.tank], -235, -clearX - 5, -150, 120, scale: 0.6)
            scatter(4, [BK.warehouse], -180, 180, back0, 200, scale: 0.7)
        case 7:     // logistics park
            row(BK.warehouse, x0: -480, x1: 480, z0: -330, z1: -330, count: 5, scale: 1.7)
            row(BK.warehouse, x0: -480, x1: 480, z0: -470, z1: -470, count: 5, scale: 1.7)
            row(BK.warehouse, x0: -clearX - 90, x1: -clearX - 90, z0: -200, z1: 200, count: 4, scale: 1.5)
            row(BK.warehouse, x0: clearX + 90, x1: clearX + 90, z0: -200, z1: 200, count: 4, scale: 1.5)
            row(BK.warehouse, x0: -420, x1: 420, z0: back0 + 60, z1: back0 + 60, count: 4, scale: 1.6)
            scatter(16, [BK.containers], -560, 560, clearFront - 60, clearFront - 15, gap: 4)
            row(BK.lamp, x0: -hl - 60, x1: hl + 60, z0: clearFront + 6, z1: clearFront + 6, count: 8)
            row(BK.lamp, x0: -hl - 60, x1: hl + 60, z0: clearBack + 6, z1: clearBack + 6, count: 8)
        case 8:     // old brickworks
            scatter(12, [BK.factory, BK.factory, BK.warehouse], -480, 480, -480, clearFront - 30)
            for (cx, cz) in [(Float(-260), Float(-300)), (-90, -360), (150, -330), (310, -280)] { add(BK.brickChimney, cx, cz) }
            scatter(6, [BK.house, BK.warehouse], -420, 420, back0, 320)
        case 11:    // city park
            ring(150, [BK.apartment, BK.apartment, BK.office, BK.office], 330, 820, gap: 7)
            ring(18, [BK.tower], 430, 900, gap: 12)
            row(BK.lamp, x0: -hl - 50, x1: hl + 50, z0: clearBack + 5, z1: clearBack + 5, count: 7)
        case 12:    // riverside: the river runs across in front, the city stands on the far bank
            scatter(110, [BK.office, BK.apartment, BK.apartment, BK.office], -820, 820, -760, -330, gap: 7)
            scatter(14, [BK.tower], -700, 700, -860, -400, gap: 12)
            scatter(60, [BK.apartment, BK.house, BK.house], -760, 760, back0, 560, gap: 6)
            add(BK.bridge, 430, -250, onWater: true)
            row(BK.lamp, x0: -360, x1: 360, z0: -168, z1: -168, count: 9)
        case 13:    // stadium car park
            add(BK.stadium, -360, -340)
            scatter(60, [BK.office, BK.apartment, BK.warehouse], -760, 760, -720, clearFront - 40, gap: 7)
            scatter(50, [BK.apartment, BK.office], -760, 760, back0, 560, gap: 7)
            scatter(16, [BK.office, BK.apartment], -760, -clearX - 30, clearFront - 40, back0)
            scatter(16, [BK.office, BK.apartment], clearX + 30, 760, clearFront - 40, back0)
            for lz in [clearFront + 8, clearBack + 6] { row(BK.lamp, x0: -hl - 80, x1: hl + 80, z0: lz, z1: lz, count: 9) }
        case 14:    // suburb: rows of houses round a playing field
            for k in 0..<4 { row(BK.house, x0: -330, x1: 330, z0: clearFront - 14 - Float(k) * 46, z1: clearFront - 14 - Float(k) * 46, count: 24) }
            for k in 0..<3 { row(BK.house, x0: -330, x1: 330, z0: back0 + Float(k) * 44, z1: back0 + Float(k) * 44, count: 24) }
            for sx in [Float(-1), 1] { for k in 0..<3 {
                let cx = sx * (clearX + 14 + Float(k) * 44)
                row(BK.house, x0: cx, x1: cx, z0: clearFront + 10, z1: clearBack - 10, count: 12)
            } }
            ring(12, [BK.apartment], 480, 760)
            add(BK.church, 380, -330); add(BK.spire, 380, -350, gap: -4)
        case 15:    // harbour promenade: water in front, the city behind
            scatter(110, [BK.office, BK.apartment, BK.office, BK.apartment], -800, 800, back0, 660, gap: 7)
            scatter(16, [BK.tower], -700, 700, back0 + 100, 800, gap: 12)
            scatter(34, [BK.apartment, BK.office], -800, -clearX - 20, -125, clearBack, gap: 7)
            scatter(34, [BK.apartment, BK.office], clearX + 20, 800, -125, clearBack, gap: 7)
            add(BK.ship, 300, -330, onWater: true)
            row(BK.lamp, x0: -420, x1: 420, z0: -138, z1: -138, count: 11)
        case 16:    // cathedral meadow: an old town across the field
            add(BK.church, 30, -300); add(BK.spire, 30, -320, gap: -4)
            scatter(120, [BK.house], -520, 520, -560, clearFront - 12, gap: 2.5)
            scatter(16, [BK.house], -480, 480, back0 + 40, 420, gap: 6)
        case 17:    // skyline
            scatter(40, [BK.tower], -700, 700, -1000, -400, gap: 12)
            scatter(90, [BK.office, BK.apartment], -820, 820, -860, -330, gap: 7)
            scatter(20, [BK.apartment, BK.house], -700, -clearX - 30, -260, 300)
            scatter(20, [BK.apartment, BK.house], clearX + 30, 700, -260, 300)
            scatter(16, [BK.apartment, BK.house], -600, 600, back0, 460)
        case 18:    // business district: an empty lot between towers
            ring(80, [BK.office, BK.office, BK.tower, BK.tower], 120, 440, gap: 10)
            ring(90, [BK.office, BK.tower, BK.apartment], 430, 860, gap: 10)
        default: break
        }
        return out
    }

    /// Meshes of the buildings. The alpha of a wall colour says what kind of front it has (see the shader):
    /// 0 plain, 0.25 industrial glazing, 0.5 flats, 0.75 offices, 1 glass tower.
    func buildDistrict() -> MeshBuilder {
        var b = MeshBuilder()
        func c(_ r: Float, _ g: Float, _ bl: Float, _ code: Float = 0) -> V4 { V4(r, g, bl, code) }
        func gableRoof(_ o: V3, _ w: Float, _ d: Float, _ h: Float, _ rise: Float, _ col: V4, wall: V4) {
            // ridge along the longer side
            let ov: Float = 0.4
            if w >= d {
                b.quad(o + V3(-w / 2 - ov, h, d / 2 + ov), o + V3(w / 2 + ov, h, d / 2 + ov), o + V3(w / 2 + ov, h + rise, 0), o + V3(-w / 2 - ov, h + rise, 0), col)
                b.quad(o + V3(w / 2 + ov, h, -d / 2 - ov), o + V3(-w / 2 - ov, h, -d / 2 - ov), o + V3(-w / 2 - ov, h + rise, 0), o + V3(w / 2 + ov, h + rise, 0), col)
                b.tri(o + V3(-w / 2, h, d / 2), o + V3(-w / 2, h, -d / 2), o + V3(-w / 2, h + rise, 0), wall)
                b.tri(o + V3(w / 2, h, -d / 2), o + V3(w / 2, h, d / 2), o + V3(w / 2, h + rise, 0), wall)
            } else {
                b.quad(o + V3(w / 2 + ov, h, d / 2 + ov), o + V3(w / 2 + ov, h, -d / 2 - ov), o + V3(0, h + rise, -d / 2 - ov), o + V3(0, h + rise, d / 2 + ov), col)
                b.quad(o + V3(-w / 2 - ov, h, -d / 2 - ov), o + V3(-w / 2 - ov, h, d / 2 + ov), o + V3(0, h + rise, d / 2 + ov), o + V3(0, h + rise, -d / 2 - ov), col)
                b.tri(o + V3(w / 2, h, d / 2), o + V3(-w / 2, h, d / 2), o + V3(0, h + rise, d / 2), wall)
                b.tri(o + V3(-w / 2, h, -d / 2), o + V3(w / 2, h, -d / 2), o + V3(0, h + rise, -d / 2), wall)
            }
        }
        func body(_ o: V3, _ w: Float, _ d: Float, _ h: Float, _ col: V4) { b.box(center: o + V3(0, h / 2 - 0.5, 0), size: V3(w, h + 1, d), color: col) }

        for blk in blocks {
            var rng = LCG(blk.seed &+ 99)
            let o = V3(blk.x, blk.y, blk.z), w = blk.w, d = blk.d, h = blk.h
            let toField: Float = blk.z < 0 ? 1 : -1          // the side that faces the flying field
            switch blk.kind {
            case BK.warehouse:
                let wall = [c(0.72, 0.74, 0.76), c(0.62, 0.68, 0.74), c(0.78, 0.76, 0.68), c(0.5, 0.56, 0.6), c(0.74, 0.72, 0.7)][Int(rng.next() * 4.99)]
                body(o, w, d, h, wall)
                gableRoof(o, w, d, h, 1.4, c(0.4, 0.42, 0.45), wall: wall)
                let doors = max(2, Int(w / 11))
                for i in 0..<doors {
                    let dx = -w / 2 + w * (Float(i) + 0.5) / Float(doors)
                    b.box(center: o + V3(dx, 2.4, toField * (d / 2 + 0.05)), size: V3(4.2, 4.8, 0.12), color: c(0.26, 0.28, 0.32))
                }
                b.box(center: o + V3(0, h - 1.2, toField * (d / 2 + 0.06)), size: V3(w * 0.5, 1.3, 0.1), color: [c(0.75, 0.12, 0.1), c(0.1, 0.3, 0.6), c(0.95, 0.7, 0.1), c(0.1, 0.45, 0.3)][Int(rng.next() * 3.99)])
            case BK.factory:
                let brick = site.district == 8
                let wall = brick ? c(0.5, 0.22, 0.16, 0.25) : c(0.6, 0.6, 0.58, 0.25)
                body(o, w, d, h, wall)
                let teeth = max(3, Int(w / 9)), tw = w / Float(teeth)
                for i in 0..<teeth {
                    let x0 = -w / 2 + tw * Float(i), x1 = x0 + tw
                    b.quad(o + V3(x0, h, d / 2), o + V3(x1, h + 3.2, d / 2), o + V3(x1, h + 3.2, -d / 2), o + V3(x0, h, -d / 2), c(0.36, 0.37, 0.4))
                    b.quad(o + V3(x1, h, d / 2), o + V3(x1, h, -d / 2), o + V3(x1, h + 3.2, -d / 2), o + V3(x1, h + 3.2, d / 2), c(0.55, 0.65, 0.7, 1))
                    b.tri(o + V3(x0, h, d / 2), o + V3(x1, h, d / 2), o + V3(x1, h + 3.2, d / 2), wall)
                    b.tri(o + V3(x1, h, -d / 2), o + V3(x0, h, -d / 2), o + V3(x1, h + 3.2, -d / 2), wall)
                }
            case BK.office:
                let wall = [c(0.78, 0.78, 0.76, 0.75), c(0.6, 0.62, 0.66, 0.75), c(0.7, 0.64, 0.56, 0.75), c(0.5, 0.52, 0.56, 0.75)][Int(rng.next() * 3.99)]
                body(o, w, d, h, wall)
                b.box(center: o + V3(w * 0.15, h + 1.2, 0), size: V3(w * 0.35, 2.4, d * 0.4), color: c(0.5, 0.5, 0.52))
            case BK.apartment:
                let wall = [c(0.86, 0.82, 0.72, 0.5), c(0.8, 0.7, 0.6, 0.5), c(0.74, 0.78, 0.8, 0.5), c(0.84, 0.84, 0.82, 0.5), c(0.72, 0.56, 0.46, 0.5)][Int(rng.next() * 4.99)]
                body(o, w, d, h, wall)
                b.box(center: o + V3(0, h + 0.25, 0), size: V3(w + 0.6, 0.5, d + 0.6), color: c(0.42, 0.42, 0.44))
            case BK.tower:
                let glass = [c(0.32, 0.42, 0.5, 1), c(0.25, 0.33, 0.42, 1), c(0.4, 0.46, 0.5, 1), c(0.3, 0.4, 0.38, 1)][Int(rng.next() * 3.99)]
                let cut = h * rng.range(0.62, 0.86)
                body(o, w, d, cut, glass)
                b.box(center: o + V3(0, (cut + h) / 2, 0), size: V3(w * 0.72, h - cut, d * 0.72), color: glass)
                b.box(center: o + V3(0, h + 1.5, 0), size: V3(w * 0.3, 3, d * 0.3), color: c(0.45, 0.46, 0.48))
                if rng.next() < 0.5 { b.cylinder(from: o + V3(0, h + 3, 0), to: o + V3(0, h + 3 + h * 0.14, 0), r0: 0.35, r1: 0.1, seg: 6, color: c(0.7, 0.7, 0.72)) }
            case BK.house:
                let wall = [c(0.9, 0.87, 0.78, 0.5), c(0.84, 0.76, 0.62, 0.5), c(0.92, 0.92, 0.9, 0.5), c(0.78, 0.66, 0.54, 0.5), c(0.8, 0.82, 0.8, 0.5)][Int(rng.next() * 4.99)]
                let roof = site.district == 16 ? c(0.6 + 0.1 * rng.next(), 0.26, 0.16) : [c(0.52, 0.24, 0.17), c(0.3, 0.3, 0.33), c(0.42, 0.3, 0.24)][Int(rng.next() * 2.99)]
                body(o, w, d, h, wall)
                gableRoof(o, w, d, h, min(w, d) * 0.42, roof, wall: wall)
                b.box(center: o + V3(w * 0.25, h + min(w, d) * 0.35, 0), size: V3(0.6, 1.6, 0.6), color: c(0.5, 0.3, 0.25))
            case BK.tank:
                let col = rng.next() < 0.6 ? c(0.9, 0.9, 0.88) : c(0.7, 0.72, 0.74)
                b.cylinder(from: o - V3(0, 1, 0), to: o + V3(0, h, 0), r0: w / 2, r1: w / 2, seg: 24, color: col)
                b.cylinder(from: o + V3(0, h, 0), to: o + V3(0, h + w * 0.08, 0), r0: w / 2, r1: 0.5, seg: 24, color: shadeC(col, 0.9))
                b.box(center: o + V3(w / 2 + 0.3, h / 2, 0), size: V3(0.5, h, 1.0), color: c(0.4, 0.4, 0.42))       // ladder
            case BK.chimney:
                let bands = 9
                for i in 0..<bands {
                    let t0 = Float(i) / Float(bands), t1 = Float(i + 1) / Float(bands)
                    let striped = i >= bands - 4
                    let col = striped ? (i % 2 == 0 ? c(0.8, 0.14, 0.1) : c(0.92, 0.92, 0.9)) : c(0.66, 0.65, 0.62)
                    b.cylinder(from: o + V3(0, h * t0 - (i == 0 ? 1 : 0), 0), to: o + V3(0, h * t1, 0), r0: w / 2 * (1 - 0.45 * t0), r1: w / 2 * (1 - 0.45 * t1), seg: 14, color: col)
                }
            case BK.cooling:
                var rings: [[V3]] = []
                for i in 0...12 {
                    let t = Float(i) / 12, k = (t - 0.75) / 0.75
                    let r = w / 2 * (0.6 + 0.4 * k * k)
                    rings.append((0..<28).map { j in let a = Float(j) / 28 * 2 * .pi; return o + V3(cos(a) * r, h * t - (i == 0 ? 1 : 0), sin(a) * r) })
                }
                b.loft(rings, color: c(0.72, 0.71, 0.68), caps: false)
            case BK.containers:
                let levels = max(1, Int(h / 2.6 + 0.5))
                let cols = [c(0.7, 0.15, 0.1), c(0.1, 0.3, 0.55), c(0.15, 0.45, 0.25), c(0.85, 0.5, 0.1), c(0.6, 0.6, 0.62), c(0.5, 0.12, 0.3), c(0.9, 0.8, 0.2)]
                for l in 0..<levels { for ix in 0..<2 { for iz in 0..<3 {
                    if l > 0 && rng.next() < 0.25 { continue }
                    b.box(center: o + V3(-3.1 + Float(ix) * 6.2, 1.3 + Float(l) * 2.6, -2.5 + Float(iz) * 2.5), size: V3(6.06, 2.56, 2.4), color: cols[Int(rng.next() * 6.99)])
                } } }
            case BK.crane:
                let col = rng.next() < 0.5 ? c(0.8, 0.2, 0.12) : c(0.15, 0.35, 0.62)
                for sx in [Float(-1), 1] { for sz in [Float(-1), 1] {
                    b.box(center: o + V3(sx * 9, 21, sz * 8), size: V3(1.6, 44, 1.6), color: col)
                } }
                b.box(center: o + V3(0, 43, 0), size: V3(20, 2.2, 18), color: col)
                b.box(center: o + V3(0, 45.5, -28), size: V3(3, 2.6, 78), color: col)                    // boom, out over the water
                b.box(center: o + V3(0, 41.5, -34), size: V3(4, 3.5, 5), color: c(0.9, 0.9, 0.88, 0.75))  // cab
                b.box(center: o + V3(0, 54, 4), size: V3(2, 16, 2), color: col)
                b.cylinder(from: o + V3(0, 61, 4), to: o + V3(0, 47, -60), r0: 0.2, r1: 0.2, seg: 4, color: c(0.3, 0.3, 0.32))
            case BK.church:
                let stone = c(0.74, 0.7, 0.62, 0.25)
                body(o, w, d, h, stone)
                gableRoof(o, w, d, h, w * 0.6, c(0.36, 0.3, 0.28), wall: stone)
            case BK.spire:
                let stone = c(0.72, 0.68, 0.6, 0.25)
                body(o, w, d, h * 0.55, stone)
                let top = o + V3(0, h, 0), y0 = h * 0.55
                let p = [o + V3(-w / 2, y0, -d / 2), o + V3(w / 2, y0, -d / 2), o + V3(w / 2, y0, d / 2), o + V3(-w / 2, y0, d / 2)]
                for i in 0..<4 { b.tri(p[(i + 1) % 4], p[i], top, c(0.3, 0.38, 0.34)) }
            case BK.gasHolder:
                b.cylinder(from: o - V3(0, 1, 0), to: o + V3(0, h * 0.8, 0), r0: w / 2 * 0.92, r1: w / 2 * 0.92, seg: 28, color: c(0.42, 0.46, 0.42))
                b.cylinder(from: o + V3(0, h * 0.8, 0), to: o + V3(0, h * 0.88, 0), r0: w / 2 * 0.92, r1: 2, seg: 28, color: c(0.36, 0.4, 0.37))
                for i in 0..<12 {
                    let a = Float(i) / 12 * 2 * .pi
                    b.box(center: o + V3(cos(a) * w / 2, h / 2, sin(a) * w / 2), size: V3(0.6, h, 0.6), color: c(0.35, 0.3, 0.27))
                }
                b.cylinder(from: o + V3(0, h - 0.4, 0), to: o + V3(0, h, 0), r0: w / 2 + 0.3, r1: w / 2 + 0.3, seg: 28, color: c(0.35, 0.3, 0.27))
            case BK.pylon:
                let steel = c(0.6, 0.62, 0.64)
                for sx in [Float(-1), 1] { for sz in [Float(-1), 1] {
                    b.cylinder(from: o + V3(sx * 3.2, 0, sz * 3.2), to: o + V3(sx * 0.5, h, sz * 0.5), r0: 0.16, r1: 0.1, seg: 4, color: steel)
                } }
                for (yy, half) in [(h * 0.62, Float(9)), (h * 0.78, 7), (h * 0.94, 5)] { b.box(center: o + V3(0, yy, 0), size: V3(half * 2, 0.35, 0.35), color: steel) }
                for yy in [h * 0.3, h * 0.5] { b.box(center: o + V3(0, yy, 0), size: V3(4.5 * (1 - yy / h) + 1.2, 0.2, 4.5 * (1 - yy / h) + 1.2), color: steel) }
            case BK.ship:
                let hull = rng.next() < 0.5 ? c(0.12, 0.14, 0.2) : c(0.45, 0.1, 0.08)
                b.box(center: o + V3(0, 3.5, 0), size: V3(w, 9, d), color: hull)
                b.box(center: o + V3(w * 0.38, 12.5, 0), size: V3(w * 0.12, 9, d * 0.8), color: c(0.93, 0.93, 0.9, 0.75))
                b.cylinder(from: o + V3(w * 0.33, 17, 0), to: o + V3(w * 0.33, 22, 0), r0: 1.8, r1: 1.5, seg: 10, color: c(0.8, 0.3, 0.1))
                let cols = [c(0.7, 0.15, 0.1), c(0.1, 0.3, 0.55), c(0.15, 0.45, 0.25), c(0.85, 0.5, 0.1), c(0.6, 0.6, 0.62)]
                var cx = -w * 0.44
                while cx < w * 0.26 {
                    let lv = 1 + Int(rng.next() * 3.9)
                    for l in 0..<lv { b.box(center: o + V3(cx + 3.1, 9.3 + Float(l) * 2.6, 0), size: V3(6.0, 2.5, d * 0.86), color: cols[Int(rng.next() * 4.99)]) }
                    cx += 6.4
                }
            case BK.stadium:
                func oval(_ a: Float, _ bb: Float, _ y: Float) -> [V3] { (0..<40).map { j in let t = Float(j) / 40 * 2 * .pi; return o + V3(cos(t) * a, y, sin(t) * bb) } }
                b.loft([oval(w / 2, d / 2, -1), oval(w / 2, d / 2, h)], color: c(0.72, 0.72, 0.72, 0.25), caps: false)
                b.loft([oval(w / 2, d / 2, h), oval(w / 2 * 0.74, d / 2 * 0.7, h * 0.94)], color: c(0.92, 0.92, 0.94), caps: false)
                b.loft([oval(w / 2 * 0.74, d / 2 * 0.7, h * 0.94), oval(w / 2 * 0.5, d / 2 * 0.44, 2)], color: c(0.3, 0.36, 0.5), caps: false)
                b.box(center: o + V3(0, 1.5, 0), size: V3(w * 0.62, 1, d * 0.5), color: c(0.2, 0.5, 0.18))
            case BK.column:
                b.cylinder(from: o - V3(0, 1, 0), to: o + V3(0, h, 0), r0: w / 2, r1: w / 2 * 0.9, seg: 12, color: c(0.75, 0.76, 0.78))
                for yy in stride(from: Float(8), to: h, by: 9) { b.cylinder(from: o + V3(0, yy, 0), to: o + V3(0, yy + 0.3, 0), r0: w / 2 + 1.1, r1: w / 2 + 1.1, seg: 12, color: c(0.5, 0.5, 0.52)) }
            case BK.hall:
                let wall = site.district == 4 ? c(0.42, 0.36, 0.33, 0.25) : c(0.64, 0.66, 0.68, 0.25)
                body(o, w, d, h, wall)
                gableRoof(o, w, d, h, 4.5, c(0.3, 0.3, 0.32), wall: wall)
                b.box(center: o + V3(0, h + 5.5, 0), size: V3(w * 0.85, 2.6, d * 0.22), color: c(0.34, 0.34, 0.36))
            case BK.lamp:
                b.cylinder(from: o, to: o + V3(0, h, 0), r0: 0.11, r1: 0.07, seg: 6, color: c(0.5, 0.5, 0.52))
                b.box(center: o + V3(0, h, toField * 0.9), size: V3(0.12, 0.12, 1.9), color: c(0.5, 0.5, 0.52))
                b.box(center: o + V3(0, h - 0.1, toField * 1.7), size: V3(0.45, 0.16, 0.8), color: c(0.95, 0.93, 0.8))
            case BK.brickChimney:
                let brick = c(0.5, 0.24, 0.17)
                func sq(_ s: Float, _ y: Float) -> [V3] { [o + V3(-s, y, -s), o + V3(s, y, -s), o + V3(s, y, s), o + V3(-s, y, s)] }
                b.loft([sq(w / 2, -1), sq(w / 2 * 0.62, h)], color: brick)
                b.box(center: o + V3(0, h + 0.3, 0), size: V3(w * 0.72, 0.6, w * 0.72), color: shadeC(brick, 0.8))
            case BK.bridge:
                b.box(center: o + V3(0, h - 0.6, 0), size: V3(w, 1.2, d), color: c(0.55, 0.55, 0.56))
                for sz in [-d * 0.3, 0, d * 0.3] { b.box(center: o + V3(0, (h - 1.2) / 2 - 3, sz), size: V3(w * 0.7, h + 5, 4), color: c(0.6, 0.6, 0.6)) }
                for sx in [Float(-1), 1] { b.box(center: o + V3(sx * (w / 2 - 0.2), h + 0.5, 0), size: V3(0.3, 1.1, d), color: c(0.75, 0.75, 0.76)) }
            default: break
            }
        }
        return b
    }
}

private func shadeC(_ c: V4, _ k: Float) -> V4 { V4(c.x * k, c.y * k, c.z * k, c.w) }
