# SafeSpace Room Photo Test Set — v0

## Purpose

A collection of 20 room photographs for repeatable SafeSpace
color-contrast experiments: four living rooms, bedrooms, kitchens,
bathrooms, and hallways.

These images are test inputs, not verified contrast measurements
or proof of room safety.

## Folder Structure

room-photos-v0/
├── README.md
├── manifest.csv
└── images/

Store original room photographs in images/ 

## Manifest Columns

| Column | Description |
|--------|-------------|
| image_id | Unique image identifier. |
| filename | Relative path to the local image. |
| source_page_url | Individual Wikimedia Commons source page. |
| source_title | Original source filename. |
| creator | Credited photographer or creator. |
| license | Selected license or dedication and version. |
| license_url | Link to its terms. |
| photo_date | Photograph date listed on the source page. |
| people_present | yes, no, or uncertain. |
| room_type | Room category. |
| source_checked_at | Date the source information was reviewed. |

Dates use YYYY-MM-DD. Photograph and source-check dates are not
download dates.

## Verification

Creator credits and licenses for all 20 images were verified from
source-page screenshots on October 14, 2026.

People labels were assigned from screenshot previews, not
full-resolution originals. Count real people, partial bodies, and
reflections—not people depicted only in artwork.

- All 20 previews: no person observed.

## Licensing and Use

Follow each image’s recorded license. Preserve required attribution,
license links, and change notices. Follow applicable share-alike
requirements when sharing modified CC BY-SA images.

Keep original images unchanged. Store experiment derivatives
separately and document their transformations.

Use the same approved dataset version for comparisons. Version
any later replacements instead of silently changing the set.

## Remaining Checks

- Confirm all 20 original images match their manifest filenames.
- Inspect full-resolution originals and update people labels.
- Obtain team approval and freeze the dataset version.