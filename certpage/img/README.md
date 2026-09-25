# Screenshots for the setup page

The page works without these: any image that is missing has its frame removed
by the browser, and the written step remains. Add them when you can; they are
what turns a six-step flow into "follow the pictures".

Keep them small. An unapproved device can reach only this page and Google, so
everything must be served from the filter itself, and the box is not fast.

| File | What to capture (iPhone) |
|---|---|
| `ios-1.png` | The "This website is trying to download a configuration profile" prompt |
| `ios-2.png` | Settings with **Profile Downloaded** visible near the top |
| `ios-3.png` | The profile screen with **Install** in the top right |
| `ios-4.png` | Settings &rsaquo; General &rsaquo; About, scrolled to **Certificate Trust Settings** |
| `ios-5.png` | Certificate Trust Settings with the **School Filter CA** switch |

| File | What to capture (Android) |
|---|---|
| `android-1.png` | The download prompt or notification |
| `android-2.png` | Settings search results for "CA certificate" |
| `android-3.png` | The **Install anyway** screen |

## Preparing them

Crop to the relevant part of the screen rather than posting a whole 6.7-inch
screenshot; the frames are about 240px wide on the page. Then shrink:

```sh
# macOS, no extra tools needed
sips -Z 480 ios-1.png --out ios-1.png
```

Aim for under ~80 KB each. Check the total:

```sh
du -ch certpage/img/*.png | tail -1
```

**Blank out anything personal** before committing: carrier name, time, other
profile names, the device name. These go in a public repository.
