# brotato:trade changelog

What each update of the [Workshop item](https://steamcommunity.com/sharedfiles/filedetails/?id=3841589038)
changed, newest first. Headings are the time of the release PR in UTC
([Releasing](../../docs/releasing.md)).

## Unreleased

## 2026-11-26 19:46 UTC

- The Trade button and its hint now follow the game's language, in all 13 of the game's
  languages. Corrections from players are welcome (see the README's Languages section).

## 2026-11-22 11:57 UTC

- Receiving a trade no longer throws you out of a menu: an item popup you have open (its buttons,
  or your own player list) stays open, with your cursor where it was, when another player gives
  you something or buys something for you. It only closes when the weapon it is about is combined
  into the one you receive. Online, a client needs the latest brotato:together for this.
- A weapon popup you keep open while you receive a trade shows its buttons for what you have
  now: Combine appears when you get a second copy of that weapon, and goes away when its twin is
  combined into the one you receive. An open list of players marks again who would combine the
  weapon.
- Online with brotato:together: the list of players someone opened to give, buy for or pass on an
  item shows on everybody's screen, as it does in local co-op.

## 2026-11-21 13:49 UTC

- A trade key instead of the Trade button right of every shop item's price (the button made the
  co-op item cards too narrow): **T** on the keyboard or **Back** on the gamepad (View on Xbox,
  Share on PlayStation, Minus on Switch) on an offered item buys it for another player, on your
  own item or weapon gives it away. The item's popup says "Press [key] to trade" while someone
  can take it. The key can be changed in the mod's config
  ([Rebinding the trade key](README.md#rebinding-the-trade-key)).
