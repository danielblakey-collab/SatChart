import { YearBatch } from "../batchValidation";
import { load2012 } from "./2012";
import { load2013 } from "./2013";
import { load2014 } from "./2014";
import { load2020 } from "./2020";
import { load2021 } from "./2021";
import { load2022 } from "./2022";
import { load2023 } from "./2023";
import { load2024 } from "./2024";


export async function loadYear(year: number): Promise<YearBatch> {
  switch (year) {
    case 2012: return load2012();
    case 2013: return load2013();
    case 2014: return load2014();
    case 2020: return load2020();
    case 2021: return load2021();
    case 2022: return load2022();
    case 2023: return load2023();
    case 2024: return load2024();
    default:
      throw new Error(`No loader implemented for year ${year}`);
  }
}
