# brotato:trade

Hand items and weapons to other players in the co-op mode of
[Brotato](https://store.steampowered.com/app/1942280/Brotato/). You can give away an item or
weapon of your own in the shop, pass on the item of a crate you open after a wave, or buy a shop
item for another player.

**Status (2026-11-18):** all three ways to trade are covered by headless tests (5 suites). What
is still open is listed under [Limitations](#limitations).

Mod id: `einfluffles-BrotatoTrade` · source: [`src/einfluffles-BrotatoTrade`](src/einfluffles-BrotatoTrade) · license: [MIT](../../LICENSE)

## Requirements

- Brotato with its Mod Loader, in a co-op run. The mod works in local co-op on its own.
- For online play, [brotato:together](../brotato-together); see [Online](#online).

## Playing

All three ways use a **Trade** button that opens a list of players, each shown as "Player 2" in
that player's colour with its character. Pick one and the item is theirs. *Cancel* (button or
key) leads back. The receiver is not asked.

| | Give (shop) | Pass on (crate) | Buy for (shop) |
|---|---|---|---|
| Where the button is | In the popup of your own item or weapon, above *Cancel* | On the crate panel, below *Take* | On every item the shop offers you, right of its price |
| Who pays | Nobody | Nobody | You, at your price |
| Players who cannot take it | Left out of the list | Listed, greyed out, and skipped by the cursor | Listed, greyed out, and skipped by the cursor |
| What the receiver gets | The item as it is, without buying effects | What *Take* would give | What a buy would give |

### Who can take an item

The game's own limits decide.

- **Items:** the item's limit holds. A player who owns a unique item is not offered another, and
  a limited item (for example 3 of a kind) goes up to its limit. What the receiver's shop offers
  right now counts too, as it does when the game rolls a shop: a player whose shop offers the
  unique item cannot be given one and then buy it as well. For a crate item, the receiver's
  locked shop items count, as the game counts them for crates.
- **Weapons** follow the game's rules for buying one. The receiver needs a free slot, or a weapon
  of the same kind to combine it with into the next tier; the list then reads
  "Player 2 (Combine)". With several weapons to combine with, a cursed one is used first. A
  receiver who takes no melee or no ranged weapons, or is limited to a tier, cannot take a weapon
  that breaks that rule.
- When nobody can take the item, the popup has no *Trade* button, and the *Trade* button of a
  crate or a shop item cannot be pressed.

### Giving an item or weapon

In the co-op shop, press *accept* on a weapon or item of your own, as you would to combine or
recycle a weapon, and choose **Trade** in the popup.

- The receiver gets the item as it is: a cursed item stays cursed, and a weapon keeps its tracked
  values.
- Buying effects do not run: no stat-gain triggers, no mutation on equip, no free reroll in the
  same shop.
- A giver whose weapons are locked cannot give any.
- Some items cannot be given away; see [What cannot be given away](#what-cannot-be-given-away).

### Passing on a crate item

When you open a crate after a wave, **Trade** hands its item to another player in your place.
Your panel then goes on to your next crate or level-up, as after *Take*. *Cancel* leads back to
*Take*, *Trade*, *Recycle* and *Ban*.

- Your own slots do not matter. With no room for a crate weapon you cannot *Take* it, but you can
  pass it on.
- The receiver takes the item the way *Take* does: stat-gain effects and mutation on equip run
  for the receiver, and a weapon without a free slot is combined.
- A meca item needs its effect picked first, as for *Take*.

### Buying for another player

**Trade** on a shop item (move right from the item, or click it online) buys that item for the
player you pick. You pay, and they get it.

- Your own slots do not matter. With 6/6 weapons you can still buy a weapon for a player with
  room, and you keep all of yours. Nothing of yours changes but your gold.
- For you it is a buy: the price is yours, with your coupons, the usual delay between two buys
  applies, the item leaves your shop (a locked one too) and your gold shakes when it is not
  enough.
- The receiver gets the item as from a buy of their own: stat-gain effects, mutation on equip,
  duplication, a weapon combined when no slot is free, and the free rerolls an item gives.
- Meca items, which have an effect to pick on the card, have no *Trade* button.

### What cannot be given away

Giving in the shop excludes the following. Passing an item back and forth would otherwise repeat
an effect that giving it away does not undo.

| Not given away | Why |
|---|---|
| Characters | A character stays with its player. |
| Builder turret, tumor, hatched eggs, used-up leftovers | The game never offers them in a shop or crate; they belong to their player's state. |
| Axolotl | Its swap of two stats is done. |
| The Leaps | Evolution would be multiplied again. |
| Handcuffs, Shackles | The cap would be set again. |
| Bait, Lure, Peacock, Celery Tea, Scarf, Weird Ghost, Hourglass | Their next-wave effect is used up when the wave starts, and the receiver would get it again. |
| Dangerous Bunny | Its free rerolls would be given again. |

### Online

The mod works online with [brotato:together](../brotato-together).

- The host needs both mods.
- A client needs brotato:trade to trade itself. Without it, it still sees what the others trade.
- A client whose host has no brotato:trade gets no *Trade* button.
- brotato:together must accept other mods' decisions: protocol 21 for the shop and protocol 30
  for crates (on its main branch since 2026-11-18). With an older one, only the host's own
  players can trade, and the host's `modloader.log` says "brotato:together is too old for ...".
- Buying for another player needs a host whose brotato:trade has that feature (builds from
  2026-11-18 on).

## Limitations

As of 2026-11-18:

- Not played in the real game. The headless tests have no renderer, so these looks are unseen:
  the character icon on a player button, the popup's height with four players, the crate panel's
  list with four players and its crate weapons below, and the *Trade* button on a shop item,
  which narrows the item's card (description and price) in the co-op panels.
- Online, a crate trade is tested on the host and on a client's side of panels set up by hand,
  not between two running games.
- Online, a cursor on a *Trade* button is shown only to players who have the mod too.
- The button text "Trade" is English in every language.
- There is no Workshop item yet.

## How it works

- **A trade is one step on the game that owns the run** (`trade/transfer.gd`). Everything is
  checked first (`trade/rules.gd`). Then the object leaves the giver's list and enters the
  receiver's in the same call, through the game's own `RunData` functions, so stats, sets and
  caches follow. Each step is counted before the next: an object that did not leave is not added
  anywhere, and one that did not arrive goes back to the giver. No frame, save or network state
  sees the object in both lists or in none.
- **UI:** the mod extends four of the game's scripts. `CoopItemPopup` gets the button and the
  list, built from the popup's own *Cancel* button. `CoopShop` decides who can take what and
  refreshes both panels afterwards. `CoopUpgradesUIPlayerContainer` gets the crate panel's button
  and list, built from its *Take* button. `UpgradesUI` does the crate hand-over.
- **Crates** (`extensions/ui/upgrades_ui.gd`): the game's own *Take* runs with the receiver as
  the one who takes. The container emits its `item_take_button_pressed` without the check of the
  giver's weapon slots, and for that press the option the panel processes names the receiver.
  `UpgradesUI._on_take_button_pressed` and `main.on_item_box_take_button_pressed` then give the
  item to the receiver and move the giver's panel on. The receiver's stats, gear and crate
  weapons are shown again, with its cursor kept in place.
- **Buying for another player** (`extensions/ui/coop_shop.gd`): the mod runs the checks of the
  shop's buy press for the giver and the room check for the receiver, then emits the shop items
  container's own `shop_item_bought` signal. `BaseShop.on_shop_item_bought` runs for the giver
  (price, coupons, the offer); only `buy_item` / `buy_weapon` are redirected to the receiver.
  The slot then behaves as after a buy, and the receiver's stats, prices, rerolls and cursor are
  refreshed. The *Trade* buttons on the shop items are built from the item's own button script
  and font.
- **Online, only the host changes the run** (`trade/together.gd`). A client's press leaves as a
  decision ("intent") of one of four kinds, and the host checks the sender and the rules again
  and applies it with the same code as a local trade. The result reaches every client with the
  host's next state.

  | Intent | Sent from | Carries |
  |---|---|---|
  | `trade.item`, `trade.weapon` | Shop | The object's place in the giver's list, its id, the receiver |
  | `trade.buy` | Shop | The shop item's place, its item's id, the receiver |
  | `trade.crate` | Crate panel | The crate item's id, the receiver |

  `trade.buy` and `trade.crate` carry the panel's revision, like the game's own presses, so a
  press on an outdated panel is dropped. `trade.item` and `trade.weapon` skip the revision, so
  two quick trades of the same item both count. That needs a brotato:together whose
  `ShopSync.register_intent` takes the `revision` argument; with an older one the second of two
  quick trades is dropped.

## Tests

`tests/einfluffles-TradeTests` is a dev-only test mod. Run it with
`tools/check.sh mods/brotato-trade`, or one suite with `tools/check.sh -s <suite>`. The
[root README](../../README.md#tests) explains how a check runs.

| Suite | What it covers |
|---|---|
| `rules` | The rules and the hand-over on `RunData`: limits, the same object in several lists, effects moving with the item, combining with the cursed weapon, nothing appearing or vanishing. |
| `shop` | The real co-op shop driven with each player's buttons: popup, list, cancel, both panels and every cursor after a trade. Buying for another player (`buy_tests.gd`): a giver with 6/6 weapons, a receiver without room, price, lock, slot and offers as for a buy, not enough gold. |
| `crate` | The crate panels on the real battle scene: the button, the list with a player who has no room, cancel, an item and a weapon passed on by a giver without a free slot, the receiver's cursor. |
| `together` | With brotato:together loaded: a remote player's request applied once on the host, a client's press only sending it, the host's state bringing the result, a client's buy for another player with the mouse and with the buttons. |
| `together_crate` | The same for a crate trade. |
