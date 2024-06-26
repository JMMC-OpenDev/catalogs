(:~
 : Reply to tabulator ajax queries
 : https://tabulator.info/docs/6.2/data#ajax-response
 : https://tabulator.info/docs/6.2/page#remote-response
 {
    "last_page":15, //the total number of available pages (this value must be greater than 0)
    "data":[ // an array of row data objects
        {id:1, name:"bob", age:"23"}, //example row data object
    ]
}
 :)
xquery version "3.1";

import module namespace templates="http://exist-db.org/xquery/html-templating";
import module namespace lib="http://exist-db.org/xquery/html-templating/lib";

import module namespace config="http://exist.jmmc.fr/catalogs/config" at "config.xqm";
import module namespace app="http://exist.jmmc.fr/catalogs/templates" at "app.xql";
import module namespace oidb-config="http://apps.jmmc.fr/exist/apps/oidb/config" at "../../oidb/modules/config.xqm";
import module namespace oidb-tap="http://apps.jmmc.fr/exist/apps/oidb/tap" at "../../oidb/modules/tap.xqm";
import module namespace jmmc-tap="http://exist.jmmc.fr/jmmc-resources/tap" at "/db/apps/jmmc-resources/content/jmmc-tap.xql";


declare namespace output = "http://www.w3.org/2010/xslt-xquery-serialization";

declare option output:method "json";
declare option output:media-type "application/json";

(: http://localhost:8080/exist/apps/catalogs/modules/tabular-data.xql?catalog=spica_calprim&token=ABC123&page=1&size=10 :)

let $catalog := request:get-parameter("catalog", () )
let $page := number(request:get-parameter("page", 1 ))
let $size := number(request:get-parameter("size", 100 ))

let $query := <q>SELECT TOP {$size} * FROM {$catalog} OFFSET {$size*($page - 1)}</q>

let $res := jmmc-tap:tap-adql-query($oidb-config:TAP_SYNC,$query, $size, "application/json")
let $data := for $d in $res?data?* return
    map:merge(
        for $m at $pos in $res?metadata?* return map:entry($m?name, array:get($d, $pos))
    )

let $count := jmmc-tap:tap-adql-query($oidb-config:TAP_SYNC,"SELECT COUNT(*) FROM "||$catalog, (), "application/json")?data?*
return
map { "last_page": ceiling($count div number($size)),
    "data": $data }
