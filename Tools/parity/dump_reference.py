"""Python 参考侧对拍脚本（不写入 Python 仓库，放在 Swift worktree）。

用法：
    CSE=couplers OUT=/tmp/py.json \
    /Users/megmeet/Documents/开发 APP/Spektrafilm/.venv/bin/python \
    Tools/parity/dump_reference.py
"""
from __future__ import annotations

import json
import os
import sys

PY_REPO = "/Users/megmeet/Documents/开发 APP/Spektrafilm"
sys.path.insert(0, os.path.join(PY_REPO, "src"))

import numpy as np  # noqa: E402

from spektrafilm.model.develop import develop_simple  # noqa: E402
from spektrafilm.model.couplers import apply_density_correction_dir_couplers  # noqa: E402
from spektrafilm.profiles.io import load_profile  # noqa: E402
from spektrafilm.runtime.params_schema import DirCouplersParams, GrainParams  # noqa: E402


def normalized_curves(curves):
    curves = np.asarray(curves, dtype=float)
    return curves - np.nanmin(curves, axis=0)


def write_json(path, payload):
    with open(path, "w") as handle:
        json.dump(payload, handle, sort_keys=True)


def main():
    case = os.environ.get("CASE", "couplers")
    out = os.environ.get("OUT", "/tmp/py_parity.json")
    film = load_profile("kodak_portra_400")

    if case == "couplers":
        curves = normalized_curves(film.data.density_curves)
        image = np.array([
            [[0.18, 0.18, 0.18],
             [0.50, 0.30, 0.20]],
            [[0.90, 0.60, 0.10],
             [0.05, 0.20, 0.50]],
        ], dtype=float)
        density = develop_simple(image, film.data.log_exposure, curves, gamma_factor=1.0)
        params = DirCouplersParams()
        density = apply_density_correction_dir_couplers(
            density,
            image,
            6.0,
            film.data.log_exposure,
            curves,
            params,
            film.info.type,
            gamma_factor=1.0,
        )
        write_json(out, {"density_cmy": [float(v) for v in np.asarray(density).ravel()]})
        return

    if case == "halation":
        from spektrafilm.model.diffusion import apply_halation_um  # noqa: E402
        from spektrafilm.runtime.params_schema import HalationParams  # noqa: E402

        width = 5
        height = 5
        image = np.zeros((height, width, 3), dtype=float)
        for y in range(height):
            for x in range(width):
                for c in range(3):
                    image[y, x, c] = (x + 1) * (y + 2) * (c + 1) / 100.0
        output = apply_halation_um(image, HalationParams(), 6.0)
        write_json(out, {"halation": [float(v) for v in np.asarray(output).ravel()]})
        return

    if case == "grain_stats":
        curves = normalized_curves(film.data.density_curves)
        levels = [0.05, 0.30, 0.60, 1.00, 1.60]
        width = 128
        height = 128
        band = height // len(levels)
        density = np.zeros((height, width, 3), dtype=float)
        for y in range(height):
            level = levels[min(y // band, len(levels) - 1)]
            density[y, :, :] = level

        from spektrafilm.model.grain import apply_grain  # noqa: E402

        output = apply_grain(
            density,
            6.0,
            GrainParams(),
            curves,
            np.asarray(film.data.density_curves_layers, dtype=float),
            film.info.type,
            use_fast_stats=True,
        )
        bands = []
        for index, level in enumerate(levels):
            start = index * band
            end = min((index + 1) * band, height)
            block = np.asarray(output[start:end])
            bands.append({
                "level": level,
                "mean": [float(v) for v in block.reshape(-1, 3).mean(axis=0)],
                "std": [float(v) for v in block.reshape(-1, 3).std(axis=0)],
            })
        write_json(out, {"bands": bands})
        return

    if case == "grain_layers":
        from spektrafilm.model.density_curves import interp_density_cmy_layers  # noqa: E402

        curves = normalized_curves(film.data.density_curves)
        density = np.array([[
            [0.10, 0.20, 0.30],
            [0.50, 0.60, 0.70],
            [1.00, 0.90, 0.80],
            [1.80, 1.50, 1.20],
        ]], dtype=float)
        layers = interp_density_cmy_layers(
            density,
            curves,
            np.asarray(film.data.density_curves_layers, dtype=float),
            positive_film=False,
        )
        write_json(out, {"layers": [float(v) for v in np.asarray(layers).ravel()]})
        return

    if case == "glare_stats":
        from spektrafilm.model.glare import add_glare  # noqa: E402
        from spektrafilm.runtime.params_schema import GlareParams  # noqa: E402

        illuminant = np.array([0.9504, 1.0, 1.0891])
        xyz = np.zeros((128, 128, 3), dtype=float)
        output = np.asarray(add_glare(xyz, illuminant, GlareParams()))
        flat = output.reshape(-1, 3)
        write_json(out, {
            "mean": [float(v) for v in flat.mean(axis=0)],
            "std": [float(v) for v in flat.std(axis=0)],
        })
        return

    if case == "diffusion_psf":
        from spektrafilm.model.diffusion import diffusion_filter_psf  # noqa: E402

        psf = {
            family: [float(v) for v in np.asarray(diffusion_filter_psf(
                (21, 21), family=family, spatial_scale=1.0,
                pixel_size_um=20.0, halo_warmth=1.0,
            )).ravel()]
            for family in ("glimmerglass", "black_pro_mist", "pro_mist", "cinebloom")
        }
        write_json(out, psf)
        return

    if case == "diffusion_apply":
        from spektrafilm.model.diffusion import apply_diffusion_filter_um  # noqa: E402
        from spektrafilm.runtime.params_schema import DiffusionFilterParams  # noqa: E402

        width = 16
        height = 16
        image = np.zeros((height, width, 3), dtype=float)
        for y in range(height):
            for x in range(width):
                image[y, x, 0] = 0.02 + 0.9 * x / 15.0
                image[y, x, 1] = 0.01 + 0.6 * y / 15.0
                image[y, x, 2] = 0.5 * np.exp(-((x - 5) ** 2 + (y - 6) ** 2) / 8.0)
        params = DiffusionFilterParams(
            active=True, filter_family="glimmerglass", strength=0.5,
        )
        output = apply_diffusion_filter_um(image, params, 20.0)
        write_json(out, {"image": [float(v) for v in np.asarray(output).ravel()]})
        return

    if case == "cam16":
        import colour  # noqa: E402

        space = colour.RGB_COLOURSPACES["sRGB"]
        xyz_w = colour.xy_to_XYZ(space.whitepoint)
        xyz = np.array([0.6273, 0.58464, 0.269])
        jab = np.asarray(colour.XYZ_to_CAM16UCS(xyz, XYZ_w=xyz_w, L_A=64, Y_b=20))
        back = np.asarray(colour.CAM16UCS_to_XYZ(jab, XYZ_w=xyz_w, L_A=64, Y_b=20))
        white_jp = float(np.asarray(
            colour.XYZ_to_CAM16UCS(xyz_w, XYZ_w=xyz_w, L_A=64, Y_b=20)
        )[0])
        write_json(out, {
            "jab": [float(v) for v in jab],
            "back": [float(v) for v in back],
            "whiteJp": white_jp,
        })
        return

    if case == "output_compress":
        from spektrafilm.utils.gamut_compression import (  # noqa: E402
            OutputGamutCompressSpec,
            compress_rgb,
        )

        rgb = np.array([
            [[0.18, 0.18, 0.18], [1.20, 0.10, -0.10]],
            [[0.05, 1.40, 0.60], [0.90, 0.85, 0.05]],
        ])
        output = compress_rgb(
            rgb,
            OutputGamutCompressSpec(algorithm=os.environ.get("ALGO", "cam16ucs")),
            output_color_space="sRGB",
        )
        write_json(out, {"rgb": [float(v) for v in np.asarray(output).ravel()]})
        return

    if case == "jzazbz":
        import colour  # noqa: E402

        space = colour.RGB_COLOURSPACES["sRGB"]
        white = colour.xy_to_XYZ(space.whitepoint)
        xyz = np.array([0.20654008, 0.12197225, 0.05136952])
        jab = np.asarray(colour.XYZ_to_Jzazbz(xyz * 100.0))
        back = np.asarray(colour.Jzazbz_to_XYZ(jab))
        white_jz = float(np.asarray(colour.XYZ_to_Jzazbz(white * 100.0))[0])
        write_json(out, {
            "jab": [float(v) for v in jab],
            "back": [float(v) for v in back],
            "whiteJz": white_jz,
        })
        return

    if case == "autoexposure":
        from spektrafilm.utils.autoexposure import measure_autoexposure_ev  # noqa: E402

        width = 320 if os.environ.get("PREVIEW") == "1" else 24
        height = 200 if os.environ.get("PREVIEW") == "1" else 16
        image = np.zeros((height, width, 3), dtype=float)
        for y in range(height):
            for x in range(width):
                value = 0.02 + 0.8 * x / (width - 1) * (y + 1) / height
                image[y, x] = (value, value * 0.7, value * 0.4)
        if os.environ.get("PREVIEW") == "1":
            from skimage.transform import rescale  # noqa: E402

            image = rescale(
                image, 256.0 / max(image.shape[0:2]), channel_axis=2, order=0
            )
        methods = ["average", "median", "center_weighted", "partial", "matrix",
                   "multi_zone", "highlight_weighted"]
        payload = {
            method: float(measure_autoexposure_ev(
                image, "ProPhoto RGB", False, method=method,
            ))
            for method in methods
        }
        write_json(out, payload)
        return

    if case == "resize":
        from skimage.transform import rescale  # noqa: E402

        width = 8
        height = 6
        image = np.zeros((height, width, 3), dtype=float)
        for y in range(height):
            for x in range(width):
                value = 0.05 + 0.9 * x / (width - 1)
                image[y, x] = (value, value * 0.6 + 0.1 * y / (height - 1), 0.2)
        output = rescale(image, 2.0, channel_axis=2, order=3)
        write_json(out, {
            "width": int(output.shape[1]),
            "height": int(output.shape[0]),
            "values": [float(v) for v in np.asarray(output).ravel()],
        })
        return

    if case == "pipeline":
        from spektrafilm.runtime.params_builder import digest_params, init_params  # noqa: E402
        from spektrafilm.runtime.pipeline import SimulationPipeline  # noqa: E402
        from spektrafilm.runtime.topology import Tap  # noqa: E402
        from spektrafilm.utils.gamut_compression import OutputGamutCompressSpec  # noqa: E402

        params = digest_params(init_params("kodak_portra_400", "kodak_supra_endura"))
        params.camera.auto_exposure = False
        params.camera.exposure_compensation_ev = 0.0
        params.camera.diffusion_filter.active = False
        params.camera.lens_blur_um = 0.0
        params.film_render.halation.active = False
        params.film_render.grain.active = os.environ.get("GRAIN") == "1"
        params.film_render.dir_couplers.active = os.environ.get("COUPLERS") == "1"
        params.print_render.glare.active = os.environ.get("GLARE") == "1"
        params.enlarger.diffusion_filter.active = os.environ.get("ENLARGER_DIFFUSION") == "1"
        if params.enlarger.diffusion_filter.active:
            params.enlarger.diffusion_filter.filter_family = "black_pro_mist"
            params.enlarger.diffusion_filter.strength = 0.5
        params.scanner.lens_blur = 0.0
        params.scanner.unsharp_mask = (0.0, 0.0)
        params.scanner.black_correction = False
        params.scanner.white_correction = False
        import dataclasses  # noqa: E402

        params.io.input_gamut_compress = dataclasses.replace(
            params.io.input_gamut_compress, active=True
        )
        params.io.output_gamut_compress = OutputGamutCompressSpec(
            algorithm=os.environ.get("OUTPUT", "off")
        )
        params.io.scan_film = False
        params.io.output_cctf_encoding = True
        params.settings.use_enlarger_lut = True
        params.settings.use_scanner_lut = True
        params.settings.lut_resolution = 17
        params.settings.use_fast_stats = False

        image = np.array([
            [[0.18, 0.18, 0.18], [0.50, 0.30, 0.20]],
            [[0.90, 0.60, 0.10], [0.05, 0.20, 0.50]],
        ], dtype=float)
        pipeline = SimulationPipeline(params)
        payload = {}
        for name in ("rgb_pre", "log_e_film", "cmy_film", "log_e_print", "cmy_print", "rgb_out"):
            value = pipeline.process(image, collect=getattr(Tap, name.upper()))
            payload[name] = [float(v) for v in np.asarray(value).ravel()]
        write_json(out, payload)
        return

    raise SystemExit(f"unknown CASE {case}")


if __name__ == "__main__":
    main()
