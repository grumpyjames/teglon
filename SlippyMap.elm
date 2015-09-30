module SlippyMap (main) where

import ArcGIS exposing (arcGIS)
import CommonLocator exposing (tiley2lat, tilex2long)
import MapBox exposing (mapBox)
import Metacarpal exposing (index, Metacarpal, InnerEvent, Event(..))
import Model exposing (Events(..), FormChange(..), FormState, ModalMessage(..), Model, Recording(..), ReplicationState(..), Sequenced, SessionState(..), Sighting, SightingForm(..), applyEvent, state)
import Osm exposing (openStreetMap)
import Results as Rs
import Styles exposing (..)
import Tile
import Tuple as T
import Types exposing (GeoPoint, Position, Tile, TileOffset, TileSource, Zoom(..))
import Ui

import Color exposing (rgb)
import Debug exposing (crash, log)
import Dict as D
import Http
import Html exposing (Attribute, Html, button, div, input, form, text, select, option, fromElement)
import Html.Attributes as Attr exposing (style)
import Html.Events exposing (Options, onClick, on, onWithOptions, onMouseDown, targetValue)
import Json.Encode as JS
import Json.Decode as JD exposing (Decoder, (:=))
import Keyboard
import List as L
import Maybe as M
import Result as R
import Signal as S
import String
import Task exposing (Task)
import Time exposing (Time)
import Window

-- need a start time
port time : Float

-- graphical hacks
port hdpi : Bool
port initialWinX : Int
port initialWinY : Int

-- location sourcing
port location : Signal (Maybe (Float, Float))
port locationError : Signal (Maybe String)

locationRequests = S.mailbox ()
port requestLocation : Signal ()
port requestLocation = locationRequests.signal

-- http replication

type alias ReplicationPacket = { maxSequence: Int, body: Http.Body }

sghtJson : Sighting -> JS.Value
sghtJson s = 
    JS.object [ ("count", JS.int s.count)
              , ("species", JS.string s.species)
              , ("location", geoJson s.location)
              , ("time", JS.float s.time)
              ]

typeNew : JS.Value
typeNew = JS.object [ ("name", JS.string "New") ]

typeRef : String -> Int -> JS.Value
typeRef n seq = JS.object [ ("name", JS.string n)
                          , ("refersTo", JS.object [("sequence", JS.int seq)])
                          ]

geoJson : GeoPoint -> JS.Value
geoJson gp = JS.object [ ("lat", JS.float gp.lat)
                       , ("lon", JS.float gp.lon)
                       ]

asJson : (Sequenced Recording) -> JS.Value
asJson r = 
    let nora typ seq item =
        JS.object [ ("sequence", (JS.int seq))
                  , ("type", typ)
                  , ("item", item) 
                  ]
    in case r.item of 
      New s -> 
          nora typeNew r.sequence <| sghtJson s
      Replace refSeq s -> 
          nora (typeRef "Replace" refSeq) r.sequence <| sghtJson s
      Delete refSeq -> 
          nora (typeRef "Delete" refSeq) r.sequence <| JS.object []

pack : List (Sequenced Recording) -> ReplicationPacket
pack rs = 
    let encode rs = Http.string <| JS.encode 0 <| JS.list <| L.map asJson rs 
    in case rs of
      [] -> ReplicationPacket -1 Http.empty
      (x :: xs) -> ReplicationPacket x.sequence (encode rs) 

postRecords : S.Address (Events) -> List (Sequenced Recording) -> Task Http.Error ()
postRecords addr rs =
    let http p = Http.post (JD.succeed (HighWaterMark p.maxSequence)) "/records" p.body 
    in http (pack rs) `Task.andThen` (S.send addr)

replicationEvents : Signal (List (Sequenced Recording))
replicationEvents = 
    let rev e = 
            case e of 
              Replicate rs -> Just rs
              otherwise -> Nothing
    in S.filterMap rev [] actions.signal 

port httpReplication : Signal (Task Http.Error ())
port httpReplication =
    S.map (postRecords actions.address) replicationEvents 

-- main
main = 
    let initialZoom = Constant 15
        initialWindow = (initialWinX, initialWinY)
        initialMouse = (False, (0,0))
        initialModel = Model hdpi greenwich initialWindow initialZoom initialMouse defaultTileSrc Nothing [] False (Just Instructions) 0 0 (ReplicatedAt time) time NotLoggedIn
    in S.map view (S.foldp applyEvent initialModel events)

-- a few useful constants
accessToken = "pk.eyJ1IjoiZ3J1bXB5amFtZXMiLCJhIjoiNWQzZjdjMDY1YTI2MjExYTQ4ZWU4YjgwZGNmNjUzZmUifQ.BpRWJBEup08Z9DJzstigvg"
mapBoxSource = mapBox hdpi "mapbox.run-bike-hike" accessToken
defaultTileSrc = mapBoxSource
greenwich = GeoPoint 51.48 0.0        

-- Signal graph and model update
actions : S.Mailbox Events
actions = S.mailbox StartingUp

devnull : S.Mailbox ()
devnull = S.mailbox ()

keyState : Signal (Int, Int)
keyState =
    let toTuple a = (a.x, a.y)
    in S.map toTuple Keyboard.arrows

events : Signal (Time, Events)
events = 
    let win = S.map WindowSize <| Window.dimensions
        keys = S.map ArrowPress <| S.map (T.multiply (256, 256)) <| keyState
        ot = S.map TouchEvent index.signal
        ls = S.map LocationReceived location
        les = S.map LocationRequestError locationError
        lrs = S.sampleOn locationRequests.signal (S.constant LocationRequestStarted)
        pulses = S.map Pulse (Time.every 2000)
    in Time.timestamp <| S.mergeMany [actions.signal, lrs, les, ls, win, keys, ot, pulses]

-- view concerns
view model = 
    let layerReady = S.forwardTo actions.address (\r -> LayerReady r)
        mapLayer = Tile.render layerReady model
        window = model.windowSize
        styles = style (absolute ++ dimensions window ++ zeroMargin)
        controls = buttons model [style absolute] actions.address locationRequests.address
        spottedLayers = spotLayers actions.address locationRequests.address model
        recentRecords = records actions.address model
        clickCatcher = div (index.attr ++ [styles]) []
        possiblyReplicate = considerReplication actions.address model
    in div [styles] ([mapLayer, clickCatcher, controls] ++ recentRecords ++ spottedLayers ++ possiblyReplicate)

replicationSpinner : List Attribute -> Html
replicationSpinner attrs = 
    Html.img 
            (  Attr.src "/ajax-loader.gif"
            :: Attr.style [("position", "absolute"), ("right", "4px"), ("bottom", "4px")]
            :: attrs
            )
            []

considerReplication : (S.Address Events) -> Model -> List Html
considerReplication addr m =
    case m.replicationState of
      ReplicatingSince t -> [
       replicationSpinner []
      ]
      ReplicatedAt t ->
          if t + 10000 < m.lastPulseTime
          then 
              let toSend = toReplicate m 
              in if (L.isEmpty toSend)
                 then []
                 else [
                  replicationSpinner [
                   on "load" (JD.succeed (Replicate toSend)) (S.message addr)
                  ]             
                 ]
          else []

toReplicate : Model -> (List (Sequenced Recording))
toReplicate m = 
    let pred r = r.sequence > m.highWaterMark 
    in L.filter pred m.records 

spotLayers : S.Address (Events) -> S.Address () -> Model -> List Html
spotLayers addr lrAddr model =
    case model.message of
      Just modalState -> 
          case modalState of
            Message message -> modalMessage addr model message
            Instructions -> modalInstructions model addr lrAddr
      Nothing -> M.withDefault [] <| M.map (\fs -> formLayers addr model fs) model.formState 
 
toSighting : SightingForm -> Result String Recording
toSighting sf =
    let countOk fs = (Rs.mapError (\a -> "count must be positive") (String.toInt fs.count)) `R.andThen` (\i -> if i > 0 then (Ok i) else (Err "count must be positive"))
        speciesNonEmpty fs c = 
            if (String.isEmpty fs.species)
            then (R.Err "Species not set")
            else (R.Ok (Sighting c fs.species fs.location fs.time))
        validate fs = (countOk fs) `R.andThen` (speciesNonEmpty fs)
    in case sf of
         JustSeen fs -> R.map New (validate fs)
         Amending seq fs -> R.map (Replace seq) (validate fs)
         PendingAmend seq fs -> R.map (Replace seq) (validate fs)

identity a = a

type alias Strings = { welcome: String 
                     , usage: String
                     , map: String
                     , drag: String
                     , zoom: String
                     , click: String
                     }

english : Strings
english = 
    Strings 
    "Welcome to birdlog.gr."
    "Use this site to log birds as you see them"
    "Tap this button to move to your current location."
    "Click (or touch) and drag to move the map around" 
    "Use these buttons to zoom in and out"
    "Double click (or tap) the map to record a sighting"
    
modalInstructions : Model -> S.Address (Events) -> S.Address () -> List Html
modalInstructions m addr lrAddr = 
    let modalBody = div [] 
                    [ text english.welcome
                    , br
                    , br
                    , text english.usage
                    , br
                    , locationButton m.locationProgress lrAddr
                    , text english.map
                    , br
                    , text english.drag
                    , br
                    , zoomIn addr
                    , zoomOut addr
                    , text english.zoom
                    , br
                    , text english.click
                    , br
                    , dismissButton addr "Ok, got it..."
                    ]
-- ourButton [("circ", True), ("zoom", True)] address (ZoomChange 1) "+"
    in [Ui.modal (S.forwardTo addr (\_ -> DismissModal)) m.windowSize modalBody] 
    
dismissButton : S.Address (Events) -> String -> Html
dismissButton addr txt = 
    button [on "click" (JD.succeed "") (\_ -> S.message addr (DismissModal))] [text txt]

modalMessage : S.Address (Events) -> Model -> String -> List Html
modalMessage addr m message = 
    let dismissAddr = S.forwardTo addr (\_ -> DismissModal)
        modalContent = div [] [text message, dismissButton addr "Ok..."]
    in [Ui.modal dismissAddr m.windowSize modalContent]

-- unwrap the formstate outside
formLayers : S.Address (Events) -> Model -> SightingForm -> List Html
formLayers addr m sf =
    let cp = fromGeopoint m ((state sf).location)
        indicators g = [tick [] [] (cp `T.add` (2, 2)), tick [] [("color", "#33AA33")] cp]
        saw = text "Spotted: "
        dismissAddr = S.forwardTo addr (\_ -> DismissModal)
        countDecoder = JD.map Count targetValue
        sendFormChange fc = S.message addr (SightingChange fc)
        count = input ((countVal sf) ++ [ Attr.id "count", Attr.type' "number", Attr.placeholder "Count, e.g 7",  on "change" countDecoder sendFormChange, on "input" countDecoder sendFormChange]) []
        speciesDecoder = JD.map Species targetValue
        bird = input ((speciesVal sf) ++ [ Attr.id "species", Attr.type' "text", Attr.placeholder "Species, e.g Puffin", on "input" speciesDecoder sendFormChange]) []
        sighting = R.map RecordChange <| toSighting sf
        decoder = JD.customDecoder (JD.succeed sighting) identity
        disabled = Rs.fold (\a -> True) (\b -> False) sighting
        deleteButton = delButton addr sf "Delete"
        submit = Ui.submitButton decoder (S.message addr) "Save" disabled
        err s = Rs.fold (\e -> [(div [Attr.class "error"] [text ("e: " ++ e)])]) (\b -> []) s
        theForm = form [style [("opacity", "0.8")]] ([saw, br, count, br, bird, br] ++ (err sighting) ++ [submit] ++ deleteButton)
    in indicators (state sf).location ++ [Ui.modal dismissAddr m.windowSize theForm]

br = Html.br [] []

delButton : S.Address (Events) -> SightingForm -> String -> List Html
delButton addr sf title = 
    case sf of 
      Amending seq _ -> [br, Ui.submitButton (JD.succeed (RecordChange (Delete seq))) (S.message addr) title False]
      PendingAmend seq _ -> [br, Ui.submitButton (JD.succeed (RecordChange (Delete seq))) (S.message addr) title False]
      otherwise -> []

val : (FormState -> String) -> SightingForm -> List Attribute
val extractor sf = 
    case sf of
      PendingAmend seq fs -> [Attr.value (extractor fs)]
      otherwise -> []

speciesVal : SightingForm -> List Attribute
speciesVal = val (\fs -> fs.species)  

countVal : SightingForm -> List Attribute
countVal = val (\fs -> fs.count)

-- tick!
tick : List Attribute -> Style -> (Int, Int) -> Html
tick attrs moreStyle g = 
    let styles = absolute ++ position (g `T.subtract` (6, 20)) ++ zeroMargin
    in div (attrs ++ [style (styles ++ moreStyle), Attr.class "tick"]) []

-- consolidate records into sightings
sightings : List (Sequenced Recording) -> List (Sequenced Sighting)
sightings rs = 
    let f r d = 
        case r.item of
          New s -> D.insert r.sequence (Sequenced r.sequence s) d
          Replace seq s -> D.insert r.sequence (Sequenced r.sequence s) <| D.remove seq d
          Delete seq -> D.remove seq d
    in D.values <| L.foldr f D.empty rs

records : S.Address (Events) -> Model -> List Html
records addr model =
    let amendAction seq = on "click" (JD.succeed seq) (\sequence -> S.message addr (AmendRecord sequence)) 
    in L.map (\s -> tick [amendAction s.sequence] [] (fromGeopoint model s.item.location)) <| sightings model.records

ons : S.Address (Events) -> Attribute
ons add = 
    let toMsg v = 
        case v of
          "OpenStreetMap" -> openStreetMap
          "ArcGIS" -> arcGIS
          "MapBox" -> mapBoxSource
    in on "change" targetValue (\v -> S.message add (TileSourceChange (toMsg v)))

tileSrcDropDown : S.Address (Events) -> Html
tileSrcDropDown address = 
    let onChange = ons address
    in select [onChange] [option [] [text "MapBox"], option [] [text "OpenStreetMap"], option [] [text "ArcGIS"]]                

zoomIn address = ourButton [("circ", True), ("zoom", True)] address (ZoomChange 1) "+"
zoomOut address = ourButton [("circ", True), ("zoom", True)] address (ZoomChange (-1)) "-"
locationButton inProgress address = ourButton [("circ", True), ("location", True), ("inprogress", inProgress)] address () ""

buttons model attrs actionAddress locationRequestAddress = 
    div attrs [zoomIn actionAddress, zoomOut actionAddress, locationButton model.locationProgress locationRequestAddress, tileSrcDropDown actionAddress]

hoverC = rgb 240 240 240
downC = rgb 235 235 235
upC = rgb 248 248 248

ourButton : List (String, Bool) -> (S.Address a) -> a -> String -> Html
ourButton classes address msg txt = 
    let events = [onClick, (\ad ms -> onWithOptions "touchend" Ui.stopEverything JD.value (\_ -> Signal.message ad ms))]
    in button ((Attr.classList classes) :: (L.map (\e -> e address msg) events)) [text txt]

-- lon min: -180
-- lat min : 85.0511
diff : TileOffset -> TileOffset -> TileOffset
diff to1 to2 =
    let posDiff = Position <| to1.position.pixels `T.subtract` to2.position.pixels
        tileDiff = Tile <| to1.tile.coordinate `T.subtract` to2.tile.coordinate
    in TileOffset tileDiff posDiff

pickZoom : Zoom -> Int
pickZoom zoom = 
    case zoom of
      Constant c -> c
      Between a b p -> b

fromGeopoint : Model -> GeoPoint -> (Int, Int)
fromGeopoint model loc =
    let win = model.windowSize
        z = toFloat <| pickZoom model.zoom
        centreOffPx = CommonLocator.toPixels model.tileSource.tileSize <| model.tileSource.locate z model.centre
        tileOffPx = CommonLocator.toPixels model.tileSource.tileSize <| model.tileSource.locate z loc        
        pixCentre = T.map (\x -> x // 2) win
        offPix = (tileOffPx `T.subtract` centreOffPx)
    in pixCentre `T.add` offPix