module ArcGIS (arcGIS) where

import CommonLocator (common)
import Types (Tile, TileSource, Zoom(..))

import Graphics.Element (Element, image)

arcGIS : TileSource
arcGIS = TileSource 256 (common 256) arcGISUrl

arcGISBase = "http://services.arcgisonline.com/ArcGIS/rest/services/World_Topo_Map/MapServer/tile/"

arcGISUrl : Zoom -> Tile -> String
arcGISUrl zoom t =
    let (x, y) = t.coordinate
        wrap z c = c % (2 ^ z) 
    in case zoom of Zoom z -> arcGISBase ++ (toString z) ++ "/" ++ (toString y) ++ "/" ++ (toString (wrap z x)) ++ ".png"