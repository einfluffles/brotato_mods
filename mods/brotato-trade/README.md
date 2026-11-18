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
  limited item (e.g. 3 of a kind) goes up to its limit. What the receiver's shop offers right now
  (locked or not) counts too, as when the game rolls the shop: a player whose shop offers the
  unique item cannot be given one on top and then buy it as well.
- **Weapons** follow the game's rules for buying one: it needs a free slot, or the receiver
  combines it with the same weapon into the next tier ("Player 2 (Combine)" in the list). With
  several weapons to combine with, a cursed one is used first. A receiver that takes no melee /
  ranged weapons or is limited to a tier is not offered; a giver whose weapons are locked cannot
  give any.
- **Not tradable:** characters, items the game never offers in a shop or crate (builder turret,
  tumor, hatched eggs, used-up leftovers) and items with an effect that giving them away does not
  undo, which passing them back and forth would farm: Axolotl (its swap is done), the Leaps
  (Evolution is multiplied anew), Handcuffs and Shackles (the cap is set anew), Bait, Lure,
  Peacock, Celery Tea, Scarf, Weird Ghost and Hourglass (their next-wave effect is used up when
  the wave starts, the receiver would get it again) and Dangerous Bunny (its free rerolls).
- The receiver gets the item as it is (cursed stays cursed, a weapon keeps its tracked values).
  Buying effects do not run: no stat-gain triggers, no mutation on equip, no free reroll in the
  same shop.

### With brotato:together

Works online with [brotato:together](../brotato-together). The host needs both mods; a client
needs brotato:trade to trade itself (without it, it still sees what the others trade). A client
whose host has no brotato:trade gets no Trade button. brotato:together must be the version with
intents for other mods (protocol 21).

### Buying for another player

Every item the shop offers you has a **Trade** button right of its price (move right from the
item, or click it online). It opens the item's popup with every other player and *Cancel*; pick
one and you buy the item for them: you pay, they get it.

- **Players without room are listed but cannot be picked** (greyed out, the cursor skips them),
  by the game's own rules for a buy: for a weapon what the shop asks before it sells one to that
  player (tier, melee / ranged, a free slot, else a weapon to combine with: "Player 2
  (Combine)"); for an item its limit (a unique item they own, counting what their own shop
  offers, as for a trade). With nobody to buy for, *Trade* cannot be pressed.
- **Your own slots do not matter**: with 6/6 weapons you can still buy a weapon for a player
  with room, and you keep all of yours. Nothing of yours changes but your gold.
- **As a buy**: the same price (yours, with your coupons), the same delay between two buys, the
  item leaves your shop (a locked one too, unlocked as by a buy) and your gold shakes when it
  is not enough. The receiver gets the item the way a buy gives it (the game's `buy_item` /
  `buy_weapon` for the receiver): stat-gain effects, mutation on equip, duplication, a weapon
  combined without a free slot, free rerolls an item gives. Meca items (an effect to pick on the
  card) have no Trade button.
- Online the press leaves as a shop intent `trade.buy` (the shop item's place, its item's id, the
  receiver) and the host buys with the same code; it needs a host with this version of
  brotato:trade.

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
- **Buying for another player** (`extensions/ui/coop_shop.gd`): the checks of the shop's buy
  press, the receiver's room by the game's rules, then the shop items container's own
  `shop_item_bought` signal: `BaseShop.on_shop_item_bought` runs for the giver (price, coupons,
  the offer), only `buy_item` / `buy_weapon` go to the receiver; then the slot goes as after a
  buy, and the receiver's part (stats, prices, rerolls) and its cursor follow. The Trade buttons
  on the shop items are built from the item's own button script and font.

## Tests

`tests/einfluffles-TradeTests` is a dev-only mod run by `tools/check.sh mods/brotato-trade`: the
rules and the hand-over on `RunData` (limits, the same object in several lists, effects moving
with the item, combining with the cursed weapon, nothing appearing or vanishing), the real co-op
shop driven with each player's buttons (popup, list, cancel, both panels and every cursor after a
trade), buying for another player (`buy_tests.gd`, run by the shop suite: a giver with 6/6
weapons, a receiver without room, price, lock, slot and offers as for a buy, not enough gold),
and a process that also loads brotato:together (a remote player's request applied once on the
host, a client's press only sending it, the host's state bringing the result; a client's buy
for another with the mouse and with the buttons).

## Open

- Not played in the real game yet: the look of the buttons (the character icon on a player
  button, the popup's height with four players) is untested, the headless tests have no renderer.
- The shop items' Trade button is untested to the eye: it narrows the item's card (its
  description and price) in the co-op panels, most of all with four players.
- No Workshop item or preview image yet.
- The button text "Trade" is English in every language.
- Online, a cursor on the Trade buttons is only shown to players who have the mod too.
