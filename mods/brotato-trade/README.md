# brotato:trade

Give items and weapons to other players in the co-op shop of
[Brotato](https://store.steampowered.com/app/1942280/Brotato/).

**Status:** new. The rules, the hand-over and the shop screen are covered by headless tests; it
has not been played in the real game yet (see *Open*).

Mod id: `einfluffles-BrotatoTrade` · source: [`src/einfluffles-BrotatoTrade`](src/einfluffles-BrotatoTrade) · license: [MIT](../../LICENSE)

## Playing

In the co-op shop, press *accept* on a weapon or item of your own, as you would to combine or
recycle a weapon. The popup has a **Trade** button above *Cancel*. It opens the list of players
who can take the item ("Player 2" in that player's colour, with its character); pick one and the
item is theirs. *Cancel* (button or key) leads back from the list.

A trade is a gift: nothing is paid and the receiver is not asked.

- **Trade only shows when somebody can take the item**, and the list only names those players.
  An item nobody can take has no popup buttons, as in the game.
- **Items:** the item's limit holds. A player who has a unique item is not offered another, a
  limited item (e.g. 3 of a kind) goes up to its limit.
- **Weapons** follow the game's rules for buying one: it needs a free slot, or the receiver
  combines it with the same weapon into the next tier ("Player 2 (Combine)" in the list). With
  several weapons to combine with, a cursed one is used first. A receiver that takes no melee /
  ranged weapons or is limited to a tier is not offered; a giver whose weapons are locked cannot
  give any.
- **Not tradable:** characters, items the game never offers in a shop or crate (builder turret,
  tumor, hatched eggs, used-up leftovers) and items whose effect was spent when they were picked up.
- The receiver gets the item as it is (cursed stays cursed, a weapon keeps its tracked values).
  Buying effects do not run: no stat-gain triggers, no mutation on equip, no free reroll in the
  same shop.

### With brotato:together

Works online with [brotato:together](../brotato-together). The host needs both mods; a client
needs brotato:trade to trade itself (without it, it still sees what the others trade). A client
whose host has no brotato:trade gets no Trade button. brotato:together must be the version with
intents for other mods (protocol 16).

## How it works

- **One step, on the game that owns the run** (`trade/transfer.gd`). Everything is checked first
  (`trade/rules.gd`), then the object leaves the giver's list and enters the receiver's in the
  same call, through the game's own `RunData` functions (so stats, sets and caches follow). Each
  step is counted before the next: an object that did not leave is not added anywhere, one that
  did not arrive goes back to the giver. No frame, save or network state sees it in both lists
  or in none.
- **Online, only the host changes the run.** A client's Trade press leaves as a shop intent
  (`trade.item` / `trade.weapon`: the object's place in the giver's list, its id, the receiver),
  with the revision of the panel it was pressed on. The host checks sender, revision, place, id
  and the rules again and applies it with the same code as a local trade. A request that arrives
  twice is applied once; the result reaches every client with the host's next shop state.
- **UI:** script extensions of the game's `CoopItemPopup` (the button and the list, built from the
  popup's own Cancel button) and `CoopShop` (who can take what, both panels afterwards).

## Tests

`tests/einfluffles-TradeTests` is a dev-only mod run by `tools/check.sh mods/brotato-trade`: the
rules and the hand-over on `RunData` (limits, the same object in several lists, effects moving
with the item, combining with the cursed weapon, nothing appearing or vanishing), the real co-op
shop driven with each player's buttons (popup, list, cancel, both panels and every cursor after a
trade), and a process that also loads brotato:together (a remote player's request applied once
on the host, a client's press only sending it, the host's state bringing the result).

## Open

- Not played in the real game yet: the look of the buttons (the character icon on a player
  button, the popup's height with four players) is untested, the headless tests have no renderer.
- No Workshop item or preview image yet.
- The button text "Trade" is English in every language.
- Online, a cursor on the Trade buttons is only shown to players who have the mod too.
