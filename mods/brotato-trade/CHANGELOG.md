# brotato:trade changelog

What each update of the [Workshop item](https://steamcommunity.com/sharedfiles/filedetails/?id=3841589038)
changed, newest first. Headings are the time of the release PR in UTC
([Releasing](../../docs/releasing.md)).

## Unreleased

- Receiving a trade no longer throws you out of a menu: an item popup you have open (its buttons,
  or your own player list) stays open, with your cursor where it was, when another player gives
  you something or buys something for you. It only closes when the weapon it is about is combined
  into the one you receive. Online, a client needs the latest brotato:together for this.
- Online with brotato:together: the list of players someone opened to give, buy for or pass on an
  item shows on everybody's screen, as it does in local co-op.

## 2026-11-21 13:49 UTC

- A trade key instead of the Trade button right of every shop item's price (the button made the
  co-op item cards too narrow): **T** on the keyboard or **Back** on the gamepad (View on Xbox,
  Share on PlayStation, Minus on Switch) on an offered item buys it for another player, on your
  own item or weapon gives it away. The item's popup says "Press [key] to trade" while someone
  can take it. The key can be changed in the mod's config
  ([Rebinding the trade key](README.md#rebinding-the-trade-key)).
