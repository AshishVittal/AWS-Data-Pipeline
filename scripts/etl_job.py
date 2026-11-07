
import sys

from awsglue.utils import getResolvedOptions
from awsglue.context import GlueContext
from awsglue.job import Job
from pyspark.context import SparkContext
from pyspark.sql.functions import col, trim, to_date
from pyspark.sql.types import (
    StructType, StructField, StringType,
    IntegerType, DoubleType
)

args = getResolvedOptions(
    sys.argv,
    ["JOB_NAME", "RAW_S3_PATH", "PROCESSED_S3_PATH"]
)

sc = SparkContext.getOrCreate()
glue_context = GlueContext(sc)
spark = glue_context.spark_session

job = Job(glue_context)
job.init(args["JOB_NAME"], args)

schema = StructType([
    StructField("order_id", StringType(), True),
    StructField("customer_id", StringType(), True),
    StructField("product", StringType(), True),
    StructField("quantity", IntegerType(), True),
    StructField("price", DoubleType(), True),
    StructField("order_date", StringType(), True),
    StructField("city", StringType(), True)
])

# Read input
orders = (
    spark.read
    .option("header", "true")
    .schema(schema)
    .csv(args["RAW_S3_PATH"])
)

input_count = orders.count()
print(f"Input records: {input_count}")

# Remove duplicate order IDs
deduplicated = orders.dropDuplicates(["order_id"])
deduplicated_count = deduplicated.count()

print(f"Records after deduplication: {deduplicated_count}")
print(f"Duplicates removed: {input_count - deduplicated_count}")

# Clean text fields and convert date
cleaned = (
    deduplicated
    .withColumn("order_id", trim(col("order_id")))
    .withColumn("customer_id", trim(col("customer_id")))
    .withColumn("product", trim(col("product")))
    .withColumn("city", trim(col("city")))
    .withColumn("order_date", to_date(col("order_date"), "yyyy-MM-dd"))
)

# Reject invalid records
valid = cleaned.filter(
    col("order_id").isNotNull()
    & (col("order_id") != "")
    & col("customer_id").isNotNull()
    & (col("customer_id") != "")
    & col("product").isNotNull()
    & (col("product") != "")
    & col("quantity").isNotNull()
    & (col("quantity") > 0)
    & col("price").isNotNull()
    & (col("price") >= 0)
    & col("order_date").isNotNull()
    & col("city").isNotNull()
    & (col("city") != "")
)

valid_count = valid.count()

print(f"Invalid records rejected: {deduplicated_count - valid_count}")
print(f"Valid records: {valid_count}")

# Calculate order value
result = valid.withColumn(
    "total_order_value",
    col("quantity") * col("price")
)

# Write Parquet output
(
    result.write
    .mode("overwrite")
    .parquet(args["PROCESSED_S3_PATH"])
)

print("ETL job completed successfully.")

job.commit()
