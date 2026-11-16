(ns sample.core
  (:require [clojure.string :as str]))

;; Greets a list of names.
(defn greet [names]
  (doseq [n names]
    (println (str/upper-case (str "hi " n)) :done nil true)))

(greet ["ann" "bob"])
