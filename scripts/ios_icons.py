"""Build legacy-compatible iOS icon PNGs for Windows IPA assembly."""
from io import BytesIO


PHONE_ICONS = (
    ("Icon", 57), ("Icon@2x", 114),
    ("Icon-20@2x", 40), ("Icon-20@3x", 60),
    ("Icon-29@2x", 58), ("Icon-29@3x", 87),
    ("Icon-40@2x", 80), ("Icon-40@3x", 120),
    ("Icon-60@2x", 120), ("Icon-60@3x", 180),
)
IPAD_ICONS = (
    ("Icon-20", 20), ("Icon-20@2x", 40),
    ("Icon-29", 29), ("Icon-29@2x", 58),
    ("Icon-40", 40), ("Icon-40@2x", 80),
    ("Icon-50", 50), ("Icon-50@2x", 100),
    ("Icon-72", 72), ("Icon-72@2x", 144),
    ("Icon-76", 76), ("Icon-76@2x", 152),
    ("Icon-83.5@2x", 167),
)


def add_extracted_icons(info, files, packaged, base):
    icon = next((directory / "icon.jpg" for directory in (packaged, base)
                 if (directory / "icon.jpg").is_file()), None)
    if icon is None:
        raise ValueError("No extracted game icon was found. Remove the private extract/ cache "
                         "and rerun extraction with complete base/update NSPs.")
    return add_app_icons(info, files, icon)


def add_app_icons(info, files, icon_path):
    """Add raster icons and legacy plist declarations without requiring actool."""
    from PIL import Image, ImageOps

    try:
        with Image.open(icon_path) as source:
            image = ImageOps.exif_transpose(source).convert("RGB")
    except (OSError, ValueError) as error:
        raise ValueError(f"Could not read extracted game icon {icon_path}: {error}") from error

    for name, size in dict((*PHONE_ICONS, *IPAD_ICONS, ("AppIcon1024", 1024))).items():
        output = BytesIO()
        image.resize((size, size), Image.Resampling.LANCZOS).save(output, format="PNG", optimize=True)
        files[f"{name}.png"] = output.getvalue()

    result = dict(info)
    for key in ("CFBundleIconName", "CFBundleIconName~ipad", "CFBundleIconFile", "CFBundleIconFiles"):
        result.pop(key, None)
    result["CFBundleIcons"] = {
        "CFBundlePrimaryIcon": {
            "CFBundleIconFiles": [name for name, _ in PHONE_ICONS],
            "UIPrerenderedIcon": False,
        }
    }
    result["CFBundleIcons~ipad"] = {
        "CFBundlePrimaryIcon": {
            "CFBundleIconFiles": [name for name, _ in IPAD_ICONS],
            "UIPrerenderedIcon": False,
        }
    }
    return result


def check_pillow():
    try:
        from PIL import Image  # noqa: F401
    except ImportError as error:
        raise ValueError("Install Pillow in the packaging Python (pip install Pillow) to embed the NSP app icon") from error
